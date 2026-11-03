/**
 * Move the kid's own wrong-answer questions (english_questions) into the paper
 * mistake bank (epaper_questions), one batch at a time.
 *
 * Why this exists: the app grew two mistake systems. `english_questions` is a
 * flat 10-question quiz; `epaper_questions` is the paper system, whose mistake
 * bank already has per-section grouping, keyword search, a two-file redo PDF and
 * the comprehension review flow. The paper bank is the one worth keeping, so the
 * quiz bank is drained into it in batches rather than in one irreversible jump —
 * the app module is only removed once this side is empty.
 *
 *   DB_PATH=~/kidreminder/kidreminder.db node migrate-quiz-to-paper.js --batch sentence_transform
 *   DB_PATH=~/kidreminder/kidreminder.db node migrate-quiz-to-paper.js --type mcq --limit 20
 *   DB_PATH=~/kidreminder/kidreminder.db node migrate-quiz-to-paper.js --ids 12,34,56
 *   DB_PATH=~/kidreminder/kidreminder.db node migrate-quiz-to-paper.js --all --dry-run
 *
 * Idempotent: the new row's source_ref is `my-wrong-answers-q<original id>`, so
 * re-running a batch updates what is already there instead of duplicating it.
 * The original row is deleted from english_questions (with its quiz items) only
 * after the paper row is written, inside one transaction.
 */
const fs = require("node:fs");
const { DatabaseSync } = require("node:sqlite");

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const val = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : null; };

const DRY_RUN = has("--dry-run");
const ALL = has("--all");
const BATCH = val("--batch");          // sentence_transform | mcq | fill_blank
const TYPE = val("--type");            // same as --batch, but explicit
const IDS = val("--ids");
const LIMIT = val("--limit") ? Number(val("--limit")) : null;

const DB_PATH = process.env.DB_PATH
  || `${process.env.HOME}/kidreminder/kidreminder.db`;
if (!fs.existsSync(DB_PATH)) {
  console.error(`db not found: ${DB_PATH}`);
  process.exit(1);
}

// The paper the migrated questions land in. Year is left NULL so it sorts last
// in the app's paper list instead of pretending to be a school prelim.
const PAPER_KEY = "my-wrong-answers";
const SCHOOL = "我的错题本";

// english_questions.type + topic -> epaper section and grading path.
// Sentence transformation lands in the synthesis section the paper runner and
// the tolerant synthesis grading already know; MCQ splits on whether the topic
// is about word meaning; a passage/editing blank becomes a cloze/open item.
function classify(row) {
  const topic = String(row.topic || "");
  if (row.type === "sentence_transform") {
    return { section: "synthesis", questionType: "fill_blank", marks: 2 };
  }
  if (row.type === "mcq") {
    const isVocab = /vocab|closest in meaning|word (choice|meaning)/i.test(topic);
    return { section: isVocab ? "vocab_mcq" : "grammar_mcq", questionType: "mcq", marks: 1 };
  }
  const isEditing = /spell|editing/i.test(topic);
  return { section: isEditing ? "editing" : "cloze_open", questionType: "fill_blank", marks: 1 };
}

const db = new DatabaseSync(DB_PATH);

let where = "1=1";
const params = [];
const wanted = BATCH || TYPE;
if (wanted) { where += " AND type = ?"; params.push(wanted); }
if (IDS) {
  const ids = IDS.split(",").map((s) => Number(s.trim())).filter(Number.isFinite);
  if (!ids.length) { console.error("--ids needs at least one id"); process.exit(1); }
  where += ` AND id IN (${ids.map(() => "?").join(",")})`;
  params.push(...ids);
}
let sql = `SELECT * FROM english_questions WHERE ${where} ORDER BY correct_count ASC, id ASC`;
if (LIMIT) sql += ` LIMIT ${LIMIT}`;

const rows = db.prepare(sql).all(...params);
if (!rows.length) { console.log("nothing matched — quiz bank unchanged"); process.exit(0); }
if (!wanted && !IDS && !ALL) {
  console.error("refusing to move the whole bank without --all (use --batch/--type/--ids, or --all)");
  process.exit(1);
}

const nextSeq = () => {
  const r = db.prepare(
    "SELECT COALESCE(MAX(paper_seq), 0) n FROM epaper_questions WHERE paper_key = ?"
  ).get(PAPER_KEY);
  return Number(r.n) + 1;
};

const existing = db.prepare("SELECT id FROM epaper_questions WHERE source_ref = ?");
const insertPaper = db.prepare(`
  INSERT INTO epaper_questions
    (source_ref, paper_key, paper_seq, school, year, section, question_type, context, passage,
     prompt, options, correct_answer, marks, image, explanation, in_mistake_bank,
     correct_count, attempts, score_total)
  VALUES (?, ?, ?, ?, NULL, ?, ?, '', '', ?, ?, ?, ?, '', ?, 1, ?, 0, 0)`);
const updatePaper = db.prepare(`
  UPDATE epaper_questions
     SET paper_seq = ?, section = ?, question_type = ?, prompt = ?, options = ?,
         correct_answer = ?, marks = ?, explanation = ?, in_mistake_bank = 1,
         correct_count = ?
   WHERE source_ref = ?`);
const delItems = db.prepare("DELETE FROM english_quiz_items WHERE question_id = ?");
const delQuestion = db.prepare("DELETE FROM english_questions WHERE id = ?");

const bySection = {};
let moved = 0, updated = 0;

try {
  db.exec("BEGIN");
  let seq = nextSeq();
  for (const row of rows) {
    const { section, questionType, marks } = classify(row);
    const sourceRef = `${PAPER_KEY}-q${row.id}`;
    const topic = String(row.topic || "").trim();
    // epaper_questions has no topic column; the topic is the useful part of what
    // the kid should learn from the item, so it rides along in the explanation
    // shown after grading (and in the parent's answer PDF).
    const explanation = topic
      ? `【${topic}】${row.explanation || ""}`.trim()
      : String(row.explanation || "");
    const options = row.options ? String(row.options) : null;

    if (existing.get(sourceRef)) {
      updatePaper.run(seq, section, questionType, row.prompt, options,
        row.correct_answer, marks, explanation, row.correct_count, sourceRef);
      updated++;
    } else {
      insertPaper.run(sourceRef, PAPER_KEY, seq, SCHOOL, section, questionType,
        row.prompt, options, row.correct_answer, marks, explanation,
        row.correct_count);
      moved++;
    }
    bySection[section] = (bySection[section] || 0) + 1;

    delItems.run(row.id);
    delQuestion.run(row.id);
    seq++;
  }
  if (DRY_RUN) { db.exec("ROLLBACK"); console.log("\n(dry run — rolled back)"); }
  else db.exec("COMMIT");
} catch (err) {
  db.exec("ROLLBACK");
  console.error("migration failed, rolled back:", err.message);
  process.exit(1);
}

const bank = db.prepare("SELECT COUNT(*) n FROM epaper_questions WHERE in_mistake_bank = 1").get().n;
const left = db.prepare("SELECT COUNT(*) n FROM english_questions").get().n;
console.log(`db: ${DB_PATH}`);
console.log(`into ${PAPER_KEY}: moved=${moved} updated=${updated} (${DRY_RUN ? "dry run" : "committed"})`);
console.log("sections:", Object.entries(bySection).map(([k, n]) => `${k}=${n}`).join(" ") || "(none)");
console.log(`paper bank now: ${bank} questions in the mistake bank`);
console.log(`quiz bank left: ${left} questions`);
