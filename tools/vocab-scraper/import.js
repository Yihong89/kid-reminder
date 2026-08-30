#!/usr/bin/env node
// Imports vocab-raw.json (scraped word bank) into kidreminder.db as a new
// `vocab_words` table. Safe to re-run — uses INSERT OR IGNORE against a
// unique index, so re-importing the same data is a no-op.
//
// Usage:
//   DB_PATH=/Users/robot/kidreminder/kidreminder.db node import.js [path/to/vocab-raw.json]

const fs = require("fs");
const path = require("path");
const { DatabaseSync } = require("node:sqlite");

const DB_PATH = process.env.DB_PATH || path.join(__dirname, "kidreminder.db");
const JSON_PATH = process.argv[2] || path.join(__dirname, "vocab-raw.json");
const SOURCE = process.env.SOURCE || "sgschoolkaki"; // 'manual' for hand-curated supplements

const data = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
console.log(`Loaded ${data.length} entries from ${JSON_PATH}`);

const db = new DatabaseSync(DB_PATH);
db.exec("PRAGMA busy_timeout = 5000;"); // be patient if the live server holds a brief lock

db.exec(`
  CREATE TABLE IF NOT EXISTS vocab_words (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    language     TEXT NOT NULL DEFAULT 'zh',   -- 'zh' now; 'en' later for English dictation
    level        TEXT NOT NULL,                 -- P1..P6
    lesson_index INTEGER NOT NULL,
    lesson       TEXT NOT NULL,                 -- e.g. "第一课"
    category     TEXT NOT NULL,                 -- 'read' (识读字) | 'write' (识写字)
    character    TEXT NOT NULL,                 -- the base 生字
    word         TEXT NOT NULL,                 -- compound word (词语)
    pinyin       TEXT NOT NULL,
    sentence     TEXT NOT NULL,                 -- example sentence
    source       TEXT NOT NULL DEFAULT 'sgschoolkaki',
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS vocab_words_unique
    ON vocab_words (language, level, lesson_index, category, character, word);
`);
console.log("vocab_words table ready.");

const insert = db.prepare(`
  INSERT OR IGNORE INTO vocab_words
    (language, level, lesson_index, lesson, category, character, word, pinyin, sentence, source)
  VALUES ('zh', ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

let inserted = 0;
db.exec("BEGIN");
try {
  for (const r of data) {
    const info = insert.run(r.level, r.lessonIndex, r.lesson, r.category, r.character, r.word, r.pinyin, r.sentence, SOURCE);
    if (info.changes) inserted++;
  }
  db.exec("COMMIT");
} catch (err) {
  db.exec("ROLLBACK");
  throw err;
}

const total = db.prepare("SELECT COUNT(*) n FROM vocab_words").get().n;
const byLevel = db.prepare("SELECT level, COUNT(*) n FROM vocab_words GROUP BY level ORDER BY level").all();
const distinctChars = db.prepare("SELECT COUNT(DISTINCT character) n FROM vocab_words").get().n;

console.log(`Inserted ${inserted} new rows (${data.length - inserted} already present / skipped).`);
console.log(`Table now has ${total} rows total, ${distinctChars} distinct characters.`);
console.log("Per level:", Object.fromEntries(byLevel.map((r) => [r.level, r.n])));
