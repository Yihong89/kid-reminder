#!/usr/bin/env node
// Imports parsed-questions.json (parsed from the kid's private wrong-answers.md
// repo — see parse_wrong_answers.py) into kidreminder.db as `english_questions`.
// Safe to re-run: uses INSERT OR IGNORE against a unique index on source_number.
//
// Usage:
//   DB_PATH=/Users/robot/kidreminder/kidreminder.db node import.js [path/to/parsed-questions.json]

const fs = require("fs");
const path = require("path");
const { DatabaseSync } = require("node:sqlite");

const DB_PATH = process.env.DB_PATH || path.join(__dirname, "kidreminder.db");
const JSON_PATH = process.argv[2] || path.join(__dirname, "parsed-questions.json");

const data = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
console.log(`Loaded ${data.length} entries from ${JSON_PATH}`);

const db = new DatabaseSync(DB_PATH);
db.exec("PRAGMA busy_timeout = 5000;");

db.exec(`
  CREATE TABLE IF NOT EXISTS english_questions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    type           TEXT NOT NULL,
    topic          TEXT NOT NULL DEFAULT '',
    prompt         TEXT NOT NULL,
    options        TEXT,
    correct_answer TEXT NOT NULL,
    explanation    TEXT NOT NULL DEFAULT '',
    needs_audio    INTEGER NOT NULL DEFAULT 0,
    correct_count  INTEGER NOT NULL DEFAULT 0,
    source_number  INTEGER,
    source         TEXT NOT NULL DEFAULT 'manual',
    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS english_questions_source_number
    ON english_questions (source_number) WHERE source_number IS NOT NULL;
`);
console.log("english_questions table ready.");

// Best-effort "does this fill-blank item need a 🔊 replay-sentence button?" rule:
// only fill_blank items (mcq/sentence_transform never get audio, per product decision),
// whose correct answer is a single word of 6+ letters that isn't a "-ing" gerund/continuous
// form (those are almost always a grammar conjugation, not a spelling-worthy vocabulary
// word). Imperfect on purpose — it's editable per-item afterwards via the admin CRUD.
function needsAudio(rec) {
  if (rec.type !== "fill_blank") return false;
  let ans = rec.correct_answer.trim();
  if (ans.includes("/")) ans = ans.split("/")[0].trim();
  if (!/^[A-Za-z'-]{6,}$/.test(ans)) return false;
  if (/ing$/i.test(ans)) return false;
  return true;
}

const insert = db.prepare(`
  INSERT OR IGNORE INTO english_questions
    (type, topic, prompt, options, correct_answer, explanation, needs_audio, source_number, source)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'wrong-answers-import')
`);

// ~34 parsed entries are meta-notes, not real questions — the original wrong-answers.md
// only recorded "student wrote X, correct answer is Y" for a comprehension-cloze/editing
// passage without copying the passage sentence itself, so there's no real prompt to show
// the kid. Skip those; they can't be turned into an answerable quiz item.
const META_MARKERS = ["Comprehension Cloze", "Editing (S&G)", "Editing —", "Editing -", "Grammar Cloze", "Vocabulary Cloze", "not captured"];
const isMetaOnly = (rec) => META_MARKERS.some((m) => rec.prompt.includes(m));

let inserted = 0, skippedMeta = 0;
db.exec("BEGIN");
try {
  for (const r of data) {
    if (isMetaOnly(r)) { skippedMeta++; continue; }
    const info = insert.run(
      r.type,
      r.topic || "",
      r.prompt,
      r.options ? JSON.stringify(r.options) : null,
      r.correct_answer,
      r.explanation || "",
      needsAudio(r) ? 1 : 0,
      r.number
    );
    if (info.changes) inserted++;
  }
  db.exec("COMMIT");
} catch (err) {
  db.exec("ROLLBACK");
  throw err;
}

const total = db.prepare("SELECT COUNT(*) n FROM english_questions").get().n;
const byType = db.prepare("SELECT type, COUNT(*) n FROM english_questions GROUP BY type").all();
const audioCount = db.prepare("SELECT COUNT(*) n FROM english_questions WHERE needs_audio = 1").get().n;

console.log(`Skipped ${skippedMeta} meta-only entries (no real sentence to show).`);
console.log(`Inserted ${inserted} new rows (${data.length - inserted - skippedMeta} already present).`);
console.log(`Table now has ${total} rows total.`);
console.log("Per type:", Object.fromEntries(byType.map((r) => [r.type, r.n])));
console.log(`Flagged needs_audio: ${audioCount}`);
