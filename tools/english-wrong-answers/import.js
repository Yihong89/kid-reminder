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

// --- duplicate guard -------------------------------------------------------
// source_number alone is not enough to keep the bank clean: the same question
// appears under several numbers (a question first logged in "Grammar: Sentence
// Transformation" and again in "New Wrong Answers (…)" or a revision-paper
// batch). When a parent deletes or edits one of those copies by hand, its
// source_number disappears from the table, and the next weekly sync happily
// re-inserts it as a "new" row — resurrecting a duplicate the family already
// dealt with (2026-09-19: #123/#124 would have come back as copies of the
// already-present #148/#149).
//
// So: before inserting, skip anything that is effectively already in the bank —
// same type, same answer, and a prompt that's mostly the same words.
const ANSWER_OF = (rec) => String(rec.correct_answer || "").split("/")[0].trim().toLowerCase();

function tokenSet(s) {
  return new Set(
    String(s || "").toLowerCase().replace(/[^a-z0-9 ]+/g, " ").split(/\s+/).filter((w) => w.length > 2)
  );
}

function jaccard(a, b) {
  const A = tokenSet(a), B = tokenSet(b);
  if (!A.size || !B.size) return 0;
  let inter = 0;
  for (const w of A) if (B.has(w)) inter++;
  return inter / (A.size + B.size - inter);
}

const existingRows = db.prepare("SELECT type, prompt, correct_answer FROM english_questions").all();
function isDuplicate(rec) {
  const ans = ANSWER_OF(rec);
  for (const row of existingRows) {
    if (row.type !== rec.type) continue;
    if (String(row.correct_answer || "").split("/")[0].trim().toLowerCase() !== ans) continue;
    if (jaccard(row.prompt, rec.prompt) >= 0.6) return true;
  }
  return false;
}

let inserted = 0, skippedMeta = 0, skippedDup = 0;
const dupSamples = [];
db.exec("BEGIN");
try {
  for (const r of data) {
    if (isMetaOnly(r)) { skippedMeta++; continue; }
    if (isDuplicate(r)) {
      skippedDup++;
      if (dupSamples.length < 5) dupSamples.push(`#${r.number} ${r.prompt.slice(0, 60)}`);
      continue;
    }
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
console.log(`Skipped ${skippedDup} duplicate entries (already in the bank under another source number).`);
for (const d of dupSamples) console.log(`  dup: ${d}`);;
console.log(`Inserted ${inserted} new rows (${data.length - inserted - skippedMeta} already present).`);
console.log(`Table now has ${total} rows total.`);
console.log("Per type:", Object.fromEntries(byType.map((r) => [r.type, r.n])));
console.log(`Flagged needs_audio: ${audioCount}`);
