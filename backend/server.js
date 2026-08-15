#!/usr/bin/env node
// Kid Reminder - simple backend server (Node.js, zero dependencies)
//
// Storage: SQLite via built-in node:sqlite
// API:
//   GET  /api/health                      -> { ok, today }
//   GET  /api/tasks                       -> today's task list (kid's app)
//   POST /api/tasks                       -> create task            [X-Admin-Pin]
//   PATCH /api/tasks/:id                  -> edit task              [X-Admin-Pin]
//   DELETE /api/tasks/:id                 -> delete task            [X-Admin-Pin]
//   POST /api/tasks/:id/toggle            -> mark done / not done   (kid's app)
//   POST /api/verify                      -> check admin PIN
//   GET  / , /admin                       -> parent web admin panel
//
// Env vars: PORT (default 2021), ADMIN_PIN (default 1234), DB_PATH

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const PORT = parseInt(process.env.PORT || "2021", 10);
const ADMIN_PIN = process.env.ADMIN_PIN || "1234";
const KID_PIN = process.env.KID_PIN || "4321"; // unlock the kid view (change before deploying)
const DB_PATH = process.env.DB_PATH || path.join(__dirname, "kidreminder.db");
const ADMIN_HTML_PATH = path.join(__dirname, "admin.html");
const SPRITES_DIR = path.join(__dirname, "sprites");

// Pokémon collection: 9 generations (Kanto..Paldea). The kid spends stamps to
// randomly unlock sprites (served from sprites/<dex>.png). A generation becomes
// available once the previous one is fully caught. Non-commercial private use of
// public PokéAPI sprite art. info.json = { "<dex>": {name, types} }.
const GENERATIONS = [
  { name: "Kanto",   start: 1,   end: 151 },
  { name: "Johto",   start: 152, end: 251 },
];
const POKEDEX_INFO = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, "sprites", "info.json"), "utf8")); }
  catch { return {}; }
})();

function pokemonInfo(dex) {
  const info = POKEDEX_INFO[String(dex)] || {};
  const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : "???");
  return { dex, name: cap(info.name || "Pokémon #" + dex), types: info.types || [] };
}

// generation index for a dex number (0-based), or null
function generationOf(dex) {
  return GENERATIONS.findIndex((g) => dex >= g.start && dex <= g.end);
}

// all dex numbers in a generation
function generationDexes(genIdx) {
  const g = GENERATIONS[genIdx];
  const out = [];
  for (let dex = g.start; dex <= g.end; dex++) out.push(dex);
  return out;
}

// which generations are playable: gen 0 always; gen N when gen N-1 fully caught
function generationAvailability(caughtSet) {
  const available = [];
  for (let i = 0; i < GENERATIONS.length; i++) {
    const prevDone = i === 0 || generationDexes(i - 1).every((dex) => caughtSet.has(dex));
    available.push(prevDone);
  }
  return available;
}

// ---------------------------------------------------------------- database
const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    emoji           TEXT NOT NULL DEFAULT '',
    recurring       INTEGER NOT NULL DEFAULT 1,   -- legacy column, kept for migration; use repeat
    repeat          TEXT NOT NULL DEFAULT 'daily',-- daily | weekly | biweekly | monthly | once
    active          INTEGER NOT NULL DEFAULT 1,
    sort            INTEGER NOT NULL DEFAULT 0,
    target_date     TEXT,                          -- task date / schedule anchor / countdown target
    countdown_enabled INTEGER NOT NULL DEFAULT 0,  -- show a countdown towards target_date
    countdown_start INTEGER NOT NULL DEFAULT 7,    -- days before target when countdown activates
    created_by      TEXT NOT NULL DEFAULT 'admin', -- "admin" | "kid" (kids can only delete their own)
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS completions (
    task_id      INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    date         TEXT NOT NULL,              -- YYYY-MM-DD (server-local)
    minutes      INTEGER NOT NULL DEFAULT 0, -- time spent completing, entered when marked done
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (task_id, date)
  );
  CREATE TABLE IF NOT EXISTS stamps (
    date         TEXT PRIMARY KEY,           -- YYYY-MM-DD (one stamp per day)
    note         TEXT NOT NULL DEFAULT '',   -- e.g. "All tasks done!"
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS unlocks (
    dex          INTEGER PRIMARY KEY,        -- 1..151 which Pokémon was unlocked
    unlocked_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);
// migrate older databases that predate newer columns
try { db.exec("ALTER TABLE completions ADD COLUMN minutes INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN target_date TEXT"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN countdown_start INTEGER NOT NULL DEFAULT 7"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN created_by TEXT NOT NULL DEFAULT 'admin'"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN parent_only INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ } // 1 = only the parent sees/manages it
try {
  db.exec("ALTER TABLE tasks ADD COLUMN repeat TEXT NOT NULL DEFAULT 'daily'");
  db.exec("UPDATE tasks SET repeat = 'once' WHERE recurring = 0"); // migrate legacy one-offs
} catch { /* exists */ }
try {
  db.exec("ALTER TABLE tasks ADD COLUMN countdown_enabled INTEGER NOT NULL DEFAULT 0");
  db.exec("UPDATE tasks SET countdown_enabled = 1 WHERE target_date IS NOT NULL"); // migrate legacy countdowns
} catch { /* exists */ }
console.log(`[kid-reminder] db ready at ${DB_PATH}`);

// ---------------------------------------------------------------- helpers
function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// daysBetween(from, to): whole days from "YYYY-MM-DD" to "YYYY-MM-DD" (can be negative)
function daysBetween(from, to) {
  const [y1, m1, d1] = from.split("-").map(Number);
  const [y2, m2, d2] = to.split("-").map(Number);
  const a = Date.UTC(y1, m1 - 1, d1);
  const b = Date.UTC(y2, m2 - 1, d2);
  return Math.round((b - a) / 86400000);
}

// scheduledOn: does a weekly / bi-weekly / monthly task fall on date d?
// anchor is the task's first date (target_date or creation date).
function scheduledOn(repeat, anchor, d) {
  if (d < anchor) return false;
  if (repeat === "weekly") return weekdayOf(d) === weekdayOf(anchor);
  if (repeat === "biweekly") return daysBetween(anchor, d) % 14 === 0;
  if (repeat === "monthly") return dayOfMonth(d) === dayOfMonth(anchor);
  return false;
}
function weekdayOf(iso) { const [y, m, dd] = iso.split("-").map(Number); return new Date(Date.UTC(y, m - 1, dd)).getUTCDay(); }
function dayOfMonth(iso) { return Number(iso.slice(8, 10)); }

// listTasks(dateStr): tasks as-of a given date (default today).
//   recurring tasks appear every day; a one-off task appears until the day it
//   is completed (then hides the next day). "done" reflects that date's record.
function listTasks(dateStr, type) {
  const d = dateStr && /^\d{4}-\d{2}-\d{2}$/.test(dateStr) ? dateStr : today();
  let sql = "SELECT * FROM tasks WHERE active = 1";
  if (type === "todo") sql += " AND countdown_enabled = 0";          // today's checklist
  if (type === "countdown") sql += " AND countdown_enabled = 1 AND target_date IS NOT NULL"; // events
  sql += " ORDER BY sort, id";
  const tasks = db.prepare(sql).all();
  const doneOn = new Map(
    db.prepare("SELECT task_id, minutes FROM completions WHERE date = ?").all(d).map((r) => [r.task_id, r.minutes])
  );
  const doneBefore = new Set(
    db.prepare("SELECT DISTINCT task_id FROM completions WHERE date < ?").all(d).map((r) => r.task_id)
  );
  const result = [];
  for (const task of tasks) {
    if (String(task.created_at).slice(0, 10) > d) continue; // not created yet on that date
    const repeat = task.repeat || "daily";
    if (repeat === "once") {
      if (task.countdown_enabled) {
        // countdown event: hide once it has any completion (today or earlier),
        // so a finished event never reappears in the countdown panel.
        if (doneBefore.has(task.id) || doneOn.has(task.id)) continue;
      } else {
        // a non-countdown one-off shows only on its own day (its date, or the
        // day it was created) and never rolls over.
        if (doneBefore.has(task.id)) continue;
        const onceDate = task.target_date || String(task.created_at).slice(0, 10);
        if (d !== onceDate) continue;
      }
    }
    const anchor = task.target_date || String(task.created_at).slice(0, 10);
    if (repeat !== "daily" && repeat !== "once" && !scheduledOn(repeat, anchor, d)) continue; // off-schedule
    result.push({
      id: task.id,
      title: task.title,
      emoji: task.emoji,
      repeat,
      done: doneOn.has(task.id),
      minutes: doneOn.get(task.id) || 0,
      targetDate: task.target_date || null,
      countdownEnabled: !!task.countdown_enabled,
      countdownStart: task.countdown_start,
      daysLeft: task.target_date ? daysBetween(d, task.target_date) : null,
      createdBy: task.created_by,
      parentOnly: !!task.parent_only,
    });
  }
  return result;
}

// toggleTask(id, minutes): mark done/undone for today. If marking done, stores
// the minutes the kid says they spent on it.
function toggleTask(id, minutes) {
  const task = db.prepare("SELECT id FROM tasks WHERE id = ? AND active = 1").get(id);
  if (!task) return { status: 404, json: { error: "task not found" } };
  const t = today();
  const existing = db.prepare("SELECT task_id FROM completions WHERE task_id = ? AND date = ?").get(id, t);
  if (existing) {
    db.prepare("DELETE FROM completions WHERE task_id = ? AND date = ?").run(id, t);
    return { status: 200, json: { done: false, minutes: 0 } };
  } else {
    const m = Math.max(0, Math.min(999, Math.round(Number(minutes) || 0)));
    db.prepare("INSERT INTO completions (task_id, date, minutes) VALUES (?, ?, ?)").run(id, t, m);
    return { status: 200, json: { done: true, minutes: m } };
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      if (!data.trim()) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch {
        reject(Object.assign(new Error("invalid JSON body"), { status: 400 }));
      }
    });
    req.on("error", reject);
  });
}

// ---------------------------------------------------------------- http server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname.replace(/\/+$/, "") || "/";
  const method = req.method;

  const sendJSON = (status, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    res.end(body);
  };

  try {
    // --- admin panel --------------------------------------------------
    if (method === "GET" && (pathname === "/" || pathname === "/admin")) {
      const html = fs.readFileSync(ADMIN_HTML_PATH);
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(html);
    }
    if (method === "GET" && pathname === "/favicon.ico") {
      return res.writeHead(204).end();
    }

    // --- Pokémon sprites (PNG images served from sprites/) ----------------
    if (method === "GET" && pathname.startsWith("/sprites/")) {
      const file = path.basename(pathname); // guard against ../ traversal
      const full = path.join(SPRITES_DIR, file);
      if (!full.startsWith(SPRITES_DIR) || !/^\d+\.png$/.test(file) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "sprite not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- sound effects (WAV served from sounds/) ---------------------------
    if (method === "GET" && pathname.startsWith("/sounds/") && pathname.endsWith(".wav")) {
      const file = path.basename(pathname); // guard against ../ traversal
      const full = path.join(__dirname, "sounds", file);
      if (!full.startsWith(path.join(__dirname, "sounds")) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "sound not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- health --------------------------------------------------------
    if (method === "GET" && pathname === "/api/health") {
      return sendJSON(200, { ok: true, today: today() });
    }

    // --- verify PIN (admin or kid) -------------------------------------
    if (method === "POST" && pathname === "/api/verify") {
      const body = await readBody(req);
      if (body.pin === ADMIN_PIN) return sendJSON(200, { ok: true, role: "admin" });
      if (body.pin === KID_PIN) return sendJSON(200, { ok: true, role: "kid" });
      return sendJSON(401, { error: "wrong pin" });
    }

    // --- tasks list (open; parent-only hidden unless admin) -------------
    if (method === "GET" && pathname === "/api/tasks") {
      const reqDate = url.searchParams.get("date") || "";
      const type = url.searchParams.get("type") || ""; // "todo" | "countdown" | "" (all)
      const date = /^\d{4}-\d{2}-\d{2}$/.test(reqDate) ? reqDate : today();
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const tasks = listTasks(date, type).filter((t) => isAdmin || !t.parentOnly);
      const todo = tasks.filter((t) => !t.countdownEnabled);
      const allDone = todo.length > 0 && todo.every((t) => t.done);
      const stamped = !!db.prepare("SELECT 1 FROM stamps WHERE date = ?").get(date);
      return sendJSON(200, { today: today(), date, type, tasks, allDone, stamped });
    }

    // --- stamps: month list (open) ----------------------------------------
    if (method === "GET" && pathname === "/api/stamps") {
      const month = url.searchParams.get("month") || "";
      const rows = month
        ? db.prepare("SELECT date FROM stamps WHERE date LIKE ? ORDER BY date").all(month + "%")
        : db.prepare("SELECT date FROM stamps ORDER BY date").all();
      return sendJSON(200, { stamps: rows.map((r) => r.date) });
    }

    // --- stats: stamp balance + collection progress (open) ---------------
    if (method === "GET" && pathname === "/api/stats") {
      const earned = db.prepare("SELECT COUNT(*) n FROM stamps").get().n;
      const caught = db.prepare("SELECT dex FROM unlocks ORDER BY dex").all().map((r) => r.dex);
      const available = Math.max(0, earned - caught.length); // each unlock spends one stamp
      const caughtSet = new Set(caught);
      const availability = generationAvailability(caughtSet);
      const generations = GENERATIONS.map((g, i) => ({
        name: g.name,
        start: g.start,
        end: g.end,
        total: g.end - g.start + 1,
        caught: generationDexes(i).filter((dex) => caughtSet.has(dex)).length,
        unlocked: availability[i],
        complete: generationDexes(i).every((dex) => caughtSet.has(dex)),
      }));
      return sendJSON(200, {
        stamps: { earned, spent: caught.length, available },
        collection: {
          total: GENERATIONS.reduce((sum, g) => sum + (g.end - g.start + 1), 0),
          caught: caught.map(pokemonInfo),
          generations,
        },
      });
    }

    // --- spend a stamp to randomly unlock a Pokémon (kid or admin) --------
    if (method === "POST" && pathname === "/api/unlock") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const genIdx = Math.max(0, Math.min(GENERATIONS.length - 1, parseInt(url.searchParams.get("gen") || "0", 10) || 0));
      const caught = new Set(db.prepare("SELECT dex FROM unlocks").all().map((r) => r.dex));
      const availability = generationAvailability(caught);
      if (!availability[genIdx]) return sendJSON(400, { error: "finish the previous generation first!" });
      const pool = generationDexes(genIdx).filter((dex) => !caught.has(dex));
      if (pool.length === 0) return sendJSON(400, { error: "this generation is complete!" });
      const earned = db.prepare("SELECT COUNT(*) n FROM stamps").get().n;
      const available = earned - caught.size;
      if (available <= 0) return sendJSON(400, { error: "no stamps to spend — earn one by finishing all tasks!" });
      // random among the uncaught dexes of this generation
      const dex = pool[Math.floor(Math.random() * pool.length)];
      db.prepare("INSERT INTO unlocks (dex) VALUES (?)").run(dex);
      const genComplete = generationDexes(genIdx).every((d) => caught.has(d) || d === dex);
      const nextGen = genComplete && genIdx + 1 < GENERATIONS.length
        ? { name: GENERATIONS[genIdx + 1].name, available: true }
        : null;
      return sendJSON(201, {
        ok: true,
        pokemon: pokemonInfo(dex),
        generation: GENERATIONS[genIdx].name,
        generationComplete: genComplete,
        nextGeneration: nextGen,
        available: available - 1,
        caught: caught.size + 1,
        total: GENERATIONS.reduce((sum, g) => sum + (g.end - g.start + 1), 0),
      });
    }

    // --- award a stamp (admin only; server verifies all-done) -------------
    if (method === "POST" && pathname === "/api/stamps") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const date = /^\d{4}-\d{2}-\d{2}$/.test(body.date || "") ? body.date : null;
      if (!date) return sendJSON(400, { error: "date (YYYY-MM-DD) is required" });
      const existing = db.prepare("SELECT 1 FROM stamps WHERE date = ?").get(date);
      if (existing) return sendJSON(409, { error: "already stamped" });
      const todo = listTasks(date, "todo").filter((t) => !t.parentOnly);
      const allDone = todo.length > 0 && todo.every((t) => t.done);
      if (!allDone && !body.force) return sendJSON(400, { error: "not all tasks are done on that day" });
      db.prepare("INSERT INTO stamps (date, note) VALUES (?, ?)").run(date, String(body.note || "All tasks done!").slice(0, 200));
      return sendJSON(201, { ok: true, date, allDone });
    }

    // --- revoke a stamp (admin only) --------------------------------------
    const stampMatch = pathname.match(/^\/api\/stamps\/(\d{4}-\d{2}-\d{2})$/);
    if (stampMatch && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const info = db.prepare("DELETE FROM stamps WHERE date = ?").run(stampMatch[1]);
      if (!info.changes) return sendJSON(404, { error: "no stamp on that day" });
      return sendJSON(200, { ok: true });
    }

    // --- create task (admin or kid) ------------------------------------
    if (method === "POST" && pathname === "/api/tasks") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const body = await readBody(req);
      const title = (body.title || "").trim();
      if (!title) return sendJSON(400, { error: "title is required" });
      const repeat = ["daily", "weekly", "biweekly", "monthly", "once"].includes(body.repeat)
        ? body.repeat
        : (typeof body.recurring === "boolean" ? (body.recurring ? "daily" : "once") : "once"); // default: once
      const targetDate = /^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null;
      const countdownEnabled = body.countdownEnabled ? 1 : 0;
      const countdownStart = Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)));
      const parentOnly = !!body.parentOnly;
      if (parentOnly && !isAdmin) return sendJSON(403, { error: "only the parent can create parent-only tasks" });
      const createdBy = isAdmin ? "admin" : "kid";
      const info = db
        .prepare("INSERT INTO tasks (title, emoji, repeat, target_date, countdown_enabled, countdown_start, created_by, parent_only) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        .run(title, String(body.emoji || "").slice(0, 8), repeat, targetDate, countdownEnabled, countdownStart, createdBy, parentOnly ? 1 : 0);
      return sendJSON(201, { id: Number(info.lastInsertRowid), createdBy });
    }

    // --- task by id -----------------------------------------------------
    const taskMatch = pathname.match(/^\/api\/tasks\/(\d+)(\/toggle)?$/);
    if (taskMatch) {
      const id = Number(taskMatch[1]);
      const isToggle = !!taskMatch[2];

      // toggle done (kid's app, open; parent-only locked for kid)
      if (method === "POST" && isToggle) {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (isKid && !isAdmin) {
          const t = db.prepare("SELECT parent_only FROM tasks WHERE id = ?").get(id);
          if (t && t.parent_only) return sendJSON(403, { error: "parent-only tasks are locked for the kid" });
        }
        const body = await readBody(req);
        const result = toggleTask(id, body.minutes);
        return sendJSON(result.status, result.json);
      }

      // edit (admin any; kid only their own tasks)
      if (method === "PATCH") {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
        const task = db.prepare("SELECT created_by, parent_only FROM tasks WHERE id = ?").get(id);
        if (!task) return sendJSON(404, { error: "task not found" });
        if (isKid) {
          if (task.parent_only) return sendJSON(403, { error: "parent-only tasks are locked for the kid" });
          if (task.created_by !== "kid") return sendJSON(403, { error: "kids can only edit their own tasks" });
        }
        const body = await readBody(req);
        if (body.parentOnly !== undefined && !isAdmin) return sendJSON(403, { error: "only the parent can change parent-only" });
        const sets = [];
        const vals = [];
        if (body.title !== undefined) { sets.push("title = ?"); vals.push(String(body.title).trim()); }
        if (body.emoji !== undefined) { sets.push("emoji = ?"); vals.push(String(body.emoji).slice(0, 8)); }
        if (body.repeat !== undefined) { sets.push("repeat = ?"); vals.push(["daily","weekly","biweekly","monthly","once"].includes(body.repeat) ? body.repeat : "once"); }
        else if (body.recurring !== undefined) { sets.push("repeat = ?"); vals.push(body.recurring ? "daily" : "once"); }
        if (body.active !== undefined) { sets.push("active = ?"); vals.push(body.active ? 1 : 0); }
        if (body.targetDate !== undefined) { sets.push("target_date = ?"); vals.push(/^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null); }
        if (body.countdownEnabled !== undefined) { sets.push("countdown_enabled = ?"); vals.push(body.countdownEnabled ? 1 : 0); }
        if (body.countdownStart !== undefined) { sets.push("countdown_start = ?"); vals.push(Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)))); }
        if (body.parentOnly !== undefined) { sets.push("parent_only = ?"); vals.push(body.parentOnly ? 1 : 0); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        const info = db.prepare(`UPDATE tasks SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
        if (!info.changes) return sendJSON(404, { error: "task not found" });
        return sendJSON(200, { ok: true });
      }

      // delete (admin any; kid only their own tasks)
      if (method === "DELETE") {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
        const task = db.prepare("SELECT created_by, parent_only FROM tasks WHERE id = ?").get(id);
        if (!task) return sendJSON(404, { error: "task not found" });
        if (!isAdmin && (task.parent_only || task.created_by !== "kid")) return sendJSON(403, { error: "kids can only delete their own tasks" });
        db.prepare("DELETE FROM tasks WHERE id = ?").run(id);
        return sendJSON(200, { ok: true });
      }
    }

    sendJSON(404, { error: "not found" });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[kid-reminder] ${method} ${pathname} -> ${status}: ${err.message}`);
    sendJSON(status, { error: status === 500 ? "server error" : err.message });
  }
});

server.listen(PORT, () => {
  console.log(`[kid-reminder] listening on http://0.0.0.0:${PORT} (admin pin: ${ADMIN_PIN})`);
});
