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
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      TEXT NOT NULL,
    emoji      TEXT NOT NULL DEFAULT '',
    recurring  INTEGER NOT NULL DEFAULT 1,   -- 1: shows every day, 0: one-off (hides once done)
    active     INTEGER NOT NULL DEFAULT 1,
    sort       INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS completions (
    task_id      INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    date         TEXT NOT NULL,              -- YYYY-MM-DD (server-local)
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (task_id, date)
  );
`);
console.log(`[kid-reminder] db ready at ${DB_PATH}`);

// ---------------------------------------------------------------- helpers
function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function listTasks() {
  const t = today();
  const tasks = db.prepare("SELECT * FROM tasks WHERE active = 1 ORDER BY sort, id").all();
  const doneToday = new Set(
    db.prepare("SELECT task_id FROM completions WHERE date = ?").all(t).map((r) => r.task_id)
  );
  const oneOffDoneBefore = new Set(
    db.prepare("SELECT task_id FROM completions WHERE date < ?").all(t).map((r) => r.task_id)
  );
  return tasks
    .filter((task) => task.recurring || !oneOffDoneBefore.has(task.id))
    .map((task) => ({
      id: task.id,
      title: task.title,
      emoji: task.emoji,
      recurring: !!task.recurring,
      done: doneToday.has(task.id),
    }));
}

function toggleTask(id) {
  const task = db.prepare("SELECT id FROM tasks WHERE id = ? AND active = 1").get(id);
  if (!task) return { status: 404, json: { error: "task not found" } };
  const t = today();
  const existing = db.prepare("SELECT task_id FROM completions WHERE task_id = ? AND date = ?").get(id, t);
  if (existing) {
    db.prepare("DELETE FROM completions WHERE task_id = ? AND date = ?").run(id, t);
    return { status: 200, json: { done: false } };
  } else {
    db.prepare("INSERT INTO completions (task_id, date) VALUES (?, ?)").run(id, t);
    return { status: 200, json: { done: true } };
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
      return sendJSON(200, { today: today(), tasks: listTasks() });
    }

    // --- create task (parent) ------------------------------------------
    if (method === "POST" && pathname === "/api/tasks") {
      if (req.headers["x-admin-pin"] !== ADMIN_PIN) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const title = (body.title || "").trim();
      if (!title) return sendJSON(400, { error: "title is required" });
      const info = db
        .prepare("INSERT INTO tasks (title, emoji, recurring) VALUES (?, ?, ?)")
        .run(title, String(body.emoji || "").slice(0, 8), body.recurring === false ? 0 : 1);
      return sendJSON(201, { id: Number(info.lastInsertRowid) });
    }

    // --- task by id -----------------------------------------------------
    const taskMatch = pathname.match(/^\/api\/tasks\/(\d+)(\/toggle)?$/);
    if (taskMatch) {
      const id = Number(taskMatch[1]);
      const isToggle = !!taskMatch[2];

      // toggle done (kid's app, open)
      if (method === "POST" && isToggle) {
        const result = toggleTask(id);
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
