#!/usr/bin/env node
/**
 * Import an extracted English Paper 2 JSON into the kid-reminder database.
 *
 * Mirrors tools/science-oeq/import.js: direct SQLite, unique index on
 * source_ref makes re-runs idempotent (UPDATE in place, never delete-then-
 * recreate mark points — node:sqlite enforces foreign keys by default, so
 * deleting a mark point that a real answer already references throws).
 *
 * Usage:
 *   node import.js aitong-2025-questions.json
 *   DB_PATH=/path/to/kidreminder.db node import.js FILE --dry-run
 */
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { DatabaseSync } = require("node:sqlite");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const file = args.find((a) => !a.startsWith("--"));
if (!file) {
  console.error("usage: node import.js <questions.json> [--dry-run]");
  process.exit(1);
}

const DB_PATH = process.env.DB_PATH
  || path.join(os.homedir(), "kidreminder", "kidreminder.db");

const data = JSON.parse(fs.readFileSync(file, "utf8"));
const questions = data.questions || [];
if (!questions.length) {
  console.error("no questions in file");
  process.exit(1);
}

const db = new DatabaseSync(DB_PATH);
db.exec("PRAGMA busy_timeout = 5000");

// Self-sufficient if run against a brand-new DB before the server has booted.
db.exec(`
  CREATE TABLE IF NOT EXISTS epaper_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT, source_ref TEXT NOT NULL,
    paper_key TEXT NOT NULL, paper_seq INTEGER NOT NULL,
    school TEXT NOT NULL DEFAULT '', year INTEGER, section TEXT NOT NULL DEFAULT '',
    question_type TEXT NOT NULL, context TEXT NOT NULL DEFAULT '', prompt TEXT NOT NULL,
    options TEXT, correct_answer TEXT, marks INTEGER NOT NULL DEFAULT 1,
    image TEXT NOT NULL DEFAULT '', explanation TEXT NOT NULL DEFAULT '',
    attempts INTEGER NOT NULL DEFAULT 0, score_total INTEGER NOT NULL DEFAULT 0,
    in_mistake_bank INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS epaper_questions_ref ON epaper_questions(source_ref);
  CREATE INDEX IF NOT EXISTS epaper_questions_paper ON epaper_questions(paper_key, paper_seq);
  CREATE TABLE IF NOT EXISTS epaper_mark_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    question_id INTEGER NOT NULL REFERENCES epaper_questions(id),
    seq INTEGER NOT NULL, point_kind TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '', keywords TEXT NOT NULL DEFAULT ''
  );
  CREATE INDEX IF NOT EXISTS epaper_mark_points_q ON epaper_mark_points(question_id);
`);

const paperKey = path.basename(file, ".json").replace(/-questions$/, "");
const meta = String(data._source || "");
const schoolGuess = meta.split(" P6")[0] || "";
const yearGuess = (meta.match(/\b(20\d\d)\b/) || [])[1];

let inserted = 0, updated = 0, points = 0, skipped = 0;
const bySection = {};

try {
  db.exec("BEGIN");
  questions.forEach((q, idx) => {
    if (!q.source_ref || !q.prompt || !q.marks || !q.question_type) {
      console.log(`  SKIP  ${q.source_ref || "(no ref)"} — missing source_ref/prompt/marks/question_type`);
      skipped++;
      return;
    }
    const mp = q.mark_points || [];
    if (q.question_type === "oeq" && mp.length !== q.marks) {
      console.log(`  SKIP  ${q.source_ref} — marks=${q.marks} but ${mp.length} mark points`);
      skipped++;
      return;
    }

    const row = [
      q.school || schoolGuess, q.year || (yearGuess ? Number(yearGuess) : null),
      q.section || "", q.question_type, q.context || "", q.passage || "", q.prompt,
      q.options ? JSON.stringify(q.options) : null, q.correct_answer || null,
      q.marks, q.image || "", q.explanation || "", paperKey, idx + 1,
    ];

    const existing = db.prepare("SELECT id FROM epaper_questions WHERE source_ref = ?").get(q.source_ref);
    let qid;
    if (existing) {
      // Preserve attempts/score_total/in_mistake_bank — re-importing a fixed
      // keyword list or corrected answer must not wipe the child's history.
      db.prepare(`UPDATE epaper_questions SET school=?, year=?, section=?, question_type=?,
        context=?, passage=?, prompt=?, options=?, correct_answer=?, marks=?, image=?, explanation=?,
        paper_key=?, paper_seq=? WHERE source_ref=?`)
        .run(...row, q.source_ref);
      qid = existing.id;
      updated++;
    } else {
      qid = db.prepare(`INSERT INTO epaper_questions
        (school, year, section, question_type, context, passage, prompt, options, correct_answer,
         marks, image, explanation, paper_key, paper_seq, source_ref)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(...row, q.source_ref).lastInsertRowid;
      inserted++;
    }
    bySection[q.section] = (bySection[q.section] || 0) + 1;

    if (q.question_type !== "oeq") return; // no mark points for objective items

    const existingPoints = db.prepare(
      "SELECT id, seq FROM epaper_mark_points WHERE question_id = ? ORDER BY seq"
    ).all(qid);
    mp.forEach((p, i) => {
      const seq = p.seq ?? i + 1;
      const fields = [p.point_kind || "", p.description || "", JSON.stringify(p.keywords || [])];
      if (i < existingPoints.length) {
        db.prepare("UPDATE epaper_mark_points SET seq=?, point_kind=?, description=?, keywords=? WHERE id=?")
          .run(seq, ...fields, existingPoints[i].id);
      } else {
        db.prepare("INSERT INTO epaper_mark_points (question_id, seq, point_kind, description, keywords) VALUES (?,?,?,?,?)")
          .run(qid, seq, ...fields);
      }
      points++;
    });
    for (let i = mp.length; i < existingPoints.length; i++) {
      try {
        db.prepare("DELETE FROM epaper_mark_points WHERE id = ?").run(existingPoints[i].id);
      } catch {
        console.log(`  NOTE  ${q.source_ref} — left an orphaned mark point, a past answer still references it`);
      }
    }
  });

  if (dryRun) {
    db.exec("ROLLBACK");
    console.log("\n(dry run — rolled back)");
  } else {
    db.exec("COMMIT");
  }
} catch (err) {
  db.exec("ROLLBACK");
  console.error("import failed, rolled back:", err.message);
  process.exit(1);
}

const totalMarks = db.prepare("SELECT COALESCE(SUM(marks),0) n FROM epaper_questions").get().n;
console.log(`\ndb: ${DB_PATH}`);
console.log(`inserted=${inserted} updated=${updated} skipped=${skipped} mark_points=${points}`);
console.log(`bank now: ${db.prepare("SELECT COUNT(*) n FROM epaper_questions").get().n} questions, ${totalMarks} marks`);
console.log("sections:", Object.entries(bySection).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join(" "));
