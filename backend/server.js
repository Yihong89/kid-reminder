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
const DB_PATH = process.env.DB_PATH || path.join(__dirname, "kidreminder.db");
const ADMIN_HTML_PATH = path.join(__dirname, "admin.html");

// ---------------------------------------------------------------- database
const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    emoji           TEXT NOT NULL DEFAULT '',
    recurring       INTEGER NOT NULL DEFAULT 1,   -- 1: shows every day, 0: one-off (hides once done)
    active          INTEGER NOT NULL DEFAULT 1,
    sort            INTEGER NOT NULL DEFAULT 0,
    target_date     TEXT,                          -- YYYY-MM-DD optional future event (countdown)
    countdown_start INTEGER NOT NULL DEFAULT 7,    -- show countdown when this many days remain
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS completions (
    task_id      INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    date         TEXT NOT NULL,              -- YYYY-MM-DD (server-local)
    minutes      INTEGER NOT NULL DEFAULT 0, -- time spent completing, entered when marked done
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (task_id, date)
  );
`);
// migrate older databases that predate newer columns
try { db.exec("ALTER TABLE completions ADD COLUMN minutes INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN target_date TEXT"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN countdown_start INTEGER NOT NULL DEFAULT 7"); } catch { /* exists */ }
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

// listTasks(dateStr): tasks as-of a given date (default today).
//   recurring tasks appear every day; a one-off task appears until the day it
//   is completed (then hides the next day). "done" reflects that date's record.
function listTasks(dateStr, type) {
  const d = dateStr && /^\d{4}-\d{2}-\d{2}$/.test(dateStr) ? dateStr : today();
  let sql = "SELECT * FROM tasks WHERE active = 1";
  if (type === "todo") sql += " AND target_date IS NULL";      // today's checklist
  if (type === "countdown") sql += " AND target_date IS NOT NULL"; // future events
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
    if (!task.recurring && doneBefore.has(task.id)) continue; // one-off done on an earlier day
    result.push({
      id: task.id,
      title: task.title,
      emoji: task.emoji,
      recurring: !!task.recurring,
      done: doneOn.has(task.id),
      minutes: doneOn.get(task.id) || 0,
      targetDate: task.target_date || null,
      countdownStart: task.countdown_start,
      daysLeft: task.target_date ? daysBetween(d, task.target_date) : null,
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
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }
    if (method === "GET" && pathname === "/favicon.ico") {
      return res.writeHead(204).end();
    }

    // --- health --------------------------------------------------------
    if (method === "GET" && pathname === "/api/health") {
      return sendJSON(200, { ok: true, today: today() });
    }

    // --- verify admin PIN ----------------------------------------------
    if (method === "POST" && pathname === "/api/verify") {
      const body = await readBody(req);
      return sendJSON(body.pin === ADMIN_PIN ? 200 : 401, body.pin === ADMIN_PIN ? { ok: true } : { error: "wrong pin" });
    }

    // --- tasks list (open) ---------------------------------------------
    if (method === "GET" && pathname === "/api/tasks") {
      const reqDate = url.searchParams.get("date") || "";
      const type = url.searchParams.get("type") || ""; // "todo" | "countdown" | "" (all)
      const date = /^\d{4}-\d{2}-\d{2}$/.test(reqDate) ? reqDate : today();
      return sendJSON(200, { today: today(), date, type, tasks: listTasks(date, type) });
    }

    // --- create task (parent) ------------------------------------------
    if (method === "POST" && pathname === "/api/tasks") {
      if (req.headers["x-admin-pin"] !== ADMIN_PIN) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const title = (body.title || "").trim();
      if (!title) return sendJSON(400, { error: "title is required" });
      const targetDate = /^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null;
      const countdownStart = Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)));
      const info = db
        .prepare("INSERT INTO tasks (title, emoji, recurring, target_date, countdown_start) VALUES (?, ?, ?, ?, ?)")
        .run(title, String(body.emoji || "").slice(0, 8), body.recurring === false ? 0 : 1, targetDate, countdownStart);
      return sendJSON(201, { id: Number(info.lastInsertRowid) });
    }

    // --- task by id -----------------------------------------------------
    const taskMatch = pathname.match(/^\/api\/tasks\/(\d+)(\/toggle)?$/);
    if (taskMatch) {
      const id = Number(taskMatch[1]);
      const isToggle = !!taskMatch[2];

      // toggle done (kid's app, open)
      if (method === "POST" && isToggle) {
        const body = await readBody(req);
        const result = toggleTask(id, body.minutes);
        return sendJSON(result.status, result.json);
      }

      // edit (parent)
      if (method === "PATCH") {
        if (req.headers["x-admin-pin"] !== ADMIN_PIN) return sendJSON(401, { error: "admin pin required" });
        const body = await readBody(req);
        const sets = [];
        const vals = [];
        if (body.title !== undefined) { sets.push("title = ?"); vals.push(String(body.title).trim()); }
        if (body.emoji !== undefined) { sets.push("emoji = ?"); vals.push(String(body.emoji).slice(0, 8)); }
        if (body.recurring !== undefined) { sets.push("recurring = ?"); vals.push(body.recurring ? 1 : 0); }
        if (body.active !== undefined) { sets.push("active = ?"); vals.push(body.active ? 1 : 0); }
        if (body.targetDate !== undefined) { sets.push("target_date = ?"); vals.push(/^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null); }
        if (body.countdownStart !== undefined) { sets.push("countdown_start = ?"); vals.push(Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)))); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        const info = db.prepare(`UPDATE tasks SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
        if (!info.changes) return sendJSON(404, { error: "task not found" });
        return sendJSON(200, { ok: true });
      }

      // delete (parent)
      if (method === "DELETE") {
        if (req.headers["x-admin-pin"] !== ADMIN_PIN) return sendJSON(401, { error: "admin pin required" });
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
