#!/usr/bin/env node
/**
 * Import an extracted Science OEQ JSON into the kid-reminder database.
 *
 * Writes directly to SQLite rather than going through the HTTP API — same
 * convention as tools/english-wrong-answers/import.js, because this is a bulk
 * load. The unique index on science_questions(source_ref) makes re-runs
 * idempotent: an existing question is UPDATEd in place and its mark points are
 * replaced, so fixing a keyword list and re-importing is safe and does not
 * orphan any answered sessions.
 *
 * Usage:
 *   node import.js acsj-2025-questions.json
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
db.exec("PRAGMA busy_timeout = 5000"); // the server holds this DB open

// The server creates these on boot, but the importer may run first on a fresh
// machine, so make it self-sufficient.
db.exec(`
  CREATE TABLE IF NOT EXISTS science_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT, source_ref TEXT NOT NULL,
    school TEXT NOT NULL DEFAULT '', year INTEGER, question_no INTEGER,
    part TEXT NOT NULL DEFAULT '', theme TEXT NOT NULL DEFAULT '',
    topic TEXT NOT NULL DEFAULT '', question_type TEXT NOT NULL DEFAULT '',
    answer_mode TEXT NOT NULL DEFAULT 'text', marks INTEGER NOT NULL,
    context TEXT NOT NULL DEFAULT '', prompt TEXT NOT NULL,
    model_answer TEXT NOT NULL DEFAULT '', image TEXT NOT NULL DEFAULT '',
    do_not_accept TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0,
    score_total INTEGER NOT NULL DEFAULT 0,
    paper_key TEXT NOT NULL DEFAULT '', paper_seq INTEGER NOT NULL DEFAULT 0,
    in_mistake_bank INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS science_questions_ref ON science_questions(source_ref);
  CREATE INDEX IF NOT EXISTS science_questions_paper ON science_questions(paper_key, paper_seq);
  CREATE TABLE IF NOT EXISTS science_mark_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    question_id INTEGER NOT NULL REFERENCES science_questions(id),
    seq INTEGER NOT NULL, point_kind TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '', keywords TEXT NOT NULL DEFAULT '',
    any_of TEXT NOT NULL DEFAULT '', need_n INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS science_mark_points_q ON science_mark_points(question_id);
`);

const meta = String(data._source || "");
const schoolGuess = meta.split(" P6")[0] || "";
const yearGuess = (meta.match(/\b(20\d\d)\b/) || [])[1];
// Groups every question in this file into one paper and preserves the exam's
// own question order (Q29a,b,c, Q30a... — the JSON array is already in that
// order), so "做完整张卷子" mode can replay it later. Derived from the
// filename rather than stored explicitly, matching source_ref's own
// "<school>-<year>-qN..." convention.
const paperKey = path.basename(file, ".json").replace(/-questions$/, "");

let inserted = 0, updated = 0, points = 0, skipped = 0;
const byKind = {};

try {
  db.exec("BEGIN");
  questions.forEach((q, idx) => {
    if (!q.source_ref || !q.prompt || !q.marks) {
      console.log(`  SKIP  ${q.source_ref || "(no ref)"} — missing source_ref/prompt/marks`);
      skipped++;
      return;
    }
    const mp = q.mark_points || [];
    if (mp.length !== q.marks) {
      // validate.py enforces this; refuse rather than store a question that
      // misrepresents how the paper is scored.
      console.log(`  SKIP  ${q.source_ref} — marks=${q.marks} but ${mp.length} mark points`);
      skipped++;
      return;
    }

    const row = [
      q.source_ref, q.school || schoolGuess, q.year || (yearGuess ? Number(yearGuess) : null),
      q.question_no ?? null, q.part || "", q.theme || "", q.topic || "",
      q.question_type || "", q.answer_mode || "text", q.marks,
      q.context || "", q.prompt, q.model_answer || "", q.image || "",
      JSON.stringify(q.do_not_accept || []), paperKey, idx + 1,
    ];

    const existing = db.prepare("SELECT id FROM science_questions WHERE source_ref = ?").get(q.source_ref);
    let qid;
    if (existing) {
      // Preserve attempts/score_total AND in_mistake_bank — re-importing a
      // corrected keyword list must not wipe the child's history with this
      // question, and must not silently clear 错题本 membership (that is a
      // parent-only action, never a side effect of re-importing).
      db.prepare(`UPDATE science_questions SET school=?, year=?, question_no=?, part=?,
        theme=?, topic=?, question_type=?, answer_mode=?, marks=?, context=?, prompt=?,
        model_answer=?, image=?, do_not_accept=?, paper_key=?, paper_seq=? WHERE source_ref=?`)
        .run(...row.slice(1), q.source_ref);
      qid = existing.id;
      updated++;
    } else {
      qid = db.prepare(`INSERT INTO science_questions
        (source_ref, school, year, question_no, part, theme, topic, question_type,
         answer_mode, marks, context, prompt, model_answer, image, do_not_accept,
         paper_key, paper_seq)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(...row).lastInsertRowid;
      inserted++;
    }

    // Update mark points IN PLACE by (question_id, seq), matching existing ids,
    // rather than delete-then-recreate. node:sqlite enforces foreign keys by
    // default (confirmed: a fresh DatabaseSync reports "foreign_keys: 1"), so
    // once a real answer has been submitted against a mark point,
    // science_item_points.mark_point_id references it and deleting that row
    // throws "FOREIGN KEY constraint failed" — which is exactly what a
    // keyword-wording fix on an already-answered question would trigger. This
    // also has the side benefit of keeping mark_point ids stable across
    // re-imports, so old session detail keeps its per-point history intact.
    const existingPoints = db.prepare(
      "SELECT id, seq FROM science_mark_points WHERE question_id = ? ORDER BY seq"
    ).all(qid);
    mp.forEach((p, i) => {
      const seq = p.seq ?? i + 1;
      const fields = [
        p.point_kind || "", p.description || "",
        p.keywords ? JSON.stringify(p.keywords) : "",
        p.any_of ? JSON.stringify(p.any_of) : "",
        p.need_n || 0,
      ];
      if (i < existingPoints.length) {
        db.prepare(`UPDATE science_mark_points
          SET seq=?, point_kind=?, description=?, keywords=?, any_of=?, need_n=?
          WHERE id=?`).run(seq, ...fields, existingPoints[i].id);
      } else {
        db.prepare(`INSERT INTO science_mark_points
          (question_id, seq, point_kind, description, keywords, any_of, need_n)
          VALUES (?,?,?,?,?,?,?)`).run(qid, seq, ...fields);
      }
      points++;
      byKind[p.point_kind] = (byKind[p.point_kind] || 0) + 1;
    });
    // The point count shrank (rare: it changes q.marks too, since
    // validate.py enforces marks == len(mark_points)). Try to remove the
    // now-unused trailing rows, but tolerate the FK error if a past session
    // already answered against one — leaving a harmless extra row is far
    // better than aborting the whole import.
    for (let i = mp.length; i < existingPoints.length; i++) {
      try {
        db.prepare("DELETE FROM science_mark_points WHERE id = ?").run(existingPoints[i].id);
      } catch {
        console.log(`  NOTE  ${q.source_ref} — left an orphaned mark point (id ${existingPoints[i].id}), a past answer still references it`);
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

const totalMarks = db.prepare("SELECT COALESCE(SUM(marks),0) n FROM science_questions").get().n;
console.log(`\ndb: ${DB_PATH}`);
console.log(`inserted=${inserted} updated=${updated} skipped=${skipped} mark_points=${points}`);
console.log(`bank now: ${db.prepare("SELECT COUNT(*) n FROM science_questions").get().n} questions, ${totalMarks} marks`);
console.log("point kinds:", Object.entries(byKind).sort((a, b) => b[1] - a[1])
  .map(([k, n]) => `${k}=${n}`).join(" "));
