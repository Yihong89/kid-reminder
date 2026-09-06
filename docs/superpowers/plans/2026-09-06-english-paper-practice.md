# 英语 PSLE 完整试卷练习模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second exam-paper practice module (英语试卷) alongside 科学, covering every
gradable question in a PSLE English Paper 2 (Language Use & Comprehension) — auto-graded
MCQ/fill-blank/editing/synthesis, plus mark-point-decomposed comprehension open-ended
questions reviewed by a parent, with an automatically computed score and a review dialog
that can correct either tier.

**Architecture:** A new, self-contained table set (`epaper_*`) parallel to (not sharing
with) both `english_questions` and `science_questions`. Backend routes and grading logic
mirror `/api/science/*` closely, extended with an instant-verdict path for objective items.
The macOS app gets a new sidebar entry and practice window mirroring `SciencePracticeView`/
`ScienceRunnerView`. `admin.html` gets a new tab mirroring the science grading dialog,
extended so either tier's verdict can be overridden. Content for the pilot (Ai Tong,
Catholic High) is authored by hand into JSON, following the exact schema this plan defines,
validated and imported with new tools mirroring `tools/science-oeq/`.

**Tech Stack:** Node.js (`node:sqlite`, zero deps) backend; vanilla-JS `admin.html`; Swift/
SwiftUI macOS app (SwiftPM, no Xcode project); Python 3 + PyMuPDF for page rendering.

**Spec:** `docs/superpowers/specs/2026-09-06-english-paper-practice-design.md`

## Global Constraints

- **Scope:** Paper 2 (Language Use & Comprehension) only. Paper 1 (composition) and any
  Listening Comprehension paper are out of scope and must never be imported.
- **Two grading tiers, one schema:** `question_type` is `'mcq' | 'fill_blank' | 'oeq'`.
  Objective tiers (`mcq`/`fill_blank`) grade instantly at submit. `oeq` uses the same
  keyword-mark-point mechanism as 科学 and stays provisional until a parent reviews it.
- **Mistake bank is sticky for every tier**, uniformly: a wrong final verdict (objective
  miss or missed oeq point) sets `in_mistake_bank = 1`; only `PATCH .../questions/:id
  {inMistakeBank:false}` ever clears it. No tier auto-clears on a later correct answer.
- **Review is not gated to `pending_review`.** Any completed session (`reviewed` or
  `pending_review`) can be reopened and re-scored; a review payload can carry objective
  corrections (`finalCorrect`), oeq point corrections (`points`), or both in the same call.
- **Score is always computed, never hand-maintained.** `epaper_sessions.score_earned` /
  `marks_total` are recomputed from current DB state every time `complete` or `review` runs
  — never incremented/decremented by hand — so there is no drift path.
- **New tables only.** Do not modify `english_questions`/`english_quiz_sessions` (a
  different, existing feature) or `science_questions`/`science_*` (also a different
  feature) to implement this.
- **Never test against the live DB or the live Mac Mini** until the final deploy task.
  Every backend task is verified with `DB_PATH=/tmp/... PORT=2099 node backend/server.js`
  against a throwaway SQLite file.
- **Repo-is-public discipline** (already established for both `english-wrong-answers` and
  `science-oeq`): paper PDFs, cropped images, and extracted question JSON are never
  committed. Only tooling and crop-config page-maps are.

---

## File Structure

| File | Responsibility |
|---|---|
| `backend/server.js` | Add `epaper_*` schema, grading helpers, and all `/api/epaper/*` + `/epaper-images/*` routes (mirrors the existing `science_*` block) |
| `backend/admin.html` | New "英语试卷" + "英语试卷错题本" tabs, a review dialog covering both tiers |
| `tools/english-papers/validate.py` | New — validates an extracted question JSON before import |
| `tools/english-papers/import.js` | New — direct-SQLite bulk importer into `epaper_*` |
| `tools/english-papers/aitong.crop.json`, `catholichigh.crop.json` | New — page-number maps (committed; structural only) |
| `tools/english-papers/aitong-2025-questions.json`, `catholichigh-2025-questions.json` | New — extracted content (gitignored) |
| `.gitignore` | Add the `tools/english-papers/` content-exclusion rules |
| `macos-app/Sources/KidReminder/Models.swift` | Add `EpaperSource`, `EpaperSessionItem`, `EpaperSession`, `EpaperSubmitResult`, `EpaperMarkPointResult`, `EpaperPaper`, `EpaperPapersResponse` |
| `macos-app/Sources/KidReminder/APIClient.swift` | Add the `epaper*` methods mirroring the `science*` ones |
| `macos-app/Sources/KidReminder/EnglishPaperPracticeView.swift` | New — papers browser (mirrors `SciencePracticeView`) |
| `macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift` | New — the practice window, branching UI per `questionType` (mirrors `ScienceRunnerView`) |
| `macos-app/Sources/KidReminder/KidReminderApp.swift` | Add `WindowGroup(id: "epaper-runner", for: EpaperSource.self)` |
| `macos-app/Sources/KidReminder/ContentView.swift` | Add a `.englishPaper` sidebar case |

---

### Task 1: Backend schema — `epaper_*` tables, image dir, audit regex

**Files:**
- Modify: `backend/server.js:67` (add `EPAPER_IMAGES_DIR` + `mkdirSync`)
- Modify: `backend/server.js:573` (insert new tables into the schema `db.exec` block, right after the `science_item_points` table/index)
- Modify: `backend/server.js:732` (`AUDIT_PATHS` regex)
- Test: manual, via `node --check` and a throwaway-DB boot

**Interfaces:**
- Produces: tables `epaper_questions`, `epaper_mark_points`, `epaper_sessions`,
  `epaper_session_items`, `epaper_item_points` exactly as specified below — every later
  task's SQL depends on these exact column names and types.

- [ ] **Step 1: Add the image directory constant next to `SCIENCE_IMAGES_DIR`**

In `backend/server.js`, right after line 67 (`const SCIENCE_IMAGES_DIR = ...`):

```js
// English Paper 2 question crops (posters/ads in the comprehension-MCQ
// section only — most of the paper is plain text). Produced offline by
// tools/english-papers/crop_questions.py. Read-only, same as science-images/.
const EPAPER_IMAGES_DIR = path.join(__dirname, "epaper-images");
```

And add `fs.mkdirSync(EPAPER_IMAGES_DIR, { recursive: true });` next to the existing
`fs.mkdirSync(SCIENCE_IMAGES_DIR, ...)` line (74).

- [ ] **Step 2: Add the five tables to the schema block**

In `backend/server.js`, insert this immediately after the `CREATE INDEX IF NOT EXISTS
science_item_points_i ...` line (573), still inside the same `db.exec(\`...\`)` call:

```sql
  -- 英语试卷 (PSLE English Paper 2, every question — not just the open-ended
  -- ones). Two grading tiers live in one table, picked by question_type:
  -- mcq/fill_blank are objectively right or wrong and grade instantly at
  -- submit; oeq (the ~10 comprehension questions per paper) is decomposed
  -- into mark points and graded like science — provisional until a parent
  -- reviews it. Mirrors science_questions' paper_key/paper_seq/
  -- in_mistake_bank shape closely on purpose.
  CREATE TABLE IF NOT EXISTS epaper_questions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    source_ref    TEXT NOT NULL,        -- e.g. 'aitong-2025-q1'; unique, idempotent re-import
    paper_key     TEXT NOT NULL,        -- e.g. 'aitong-2025'
    paper_seq     INTEGER NOT NULL,     -- original question order in the paper
    school        TEXT NOT NULL DEFAULT '',
    year          INTEGER,
    section       TEXT NOT NULL DEFAULT '',   -- grammar_mcq | vocab_mcq | cloze_mcq |
                                                -- comprehension_mcq | cloze_wordbank |
                                                -- editing | cloze_open | synthesis |
                                                -- comprehension_oeq
    question_type TEXT NOT NULL,         -- 'mcq' | 'fill_blank' | 'oeq'  (grading path)
    context       TEXT NOT NULL DEFAULT '', -- shared passage/cloze text shown above the prompt
    prompt        TEXT NOT NULL,
    options       TEXT,                  -- JSON array of strings, mcq only
    correct_answer TEXT,                 -- mcq/fill_blank only; "alt1 / alt2" = either counts
    marks         INTEGER NOT NULL DEFAULT 1,
    image         TEXT NOT NULL DEFAULT '',  -- filename in epaper-images/, posters/ads only
    explanation   TEXT NOT NULL DEFAULT '',  -- shown after grading; doubles as oeq model answer
    attempts      INTEGER NOT NULL DEFAULT 0,
    score_total   INTEGER NOT NULL DEFAULT 0,   -- unfloored, same reasoning as science
    in_mistake_bank INTEGER NOT NULL DEFAULT 0, -- sticky; parent-clear only, all tiers
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS epaper_questions_ref ON epaper_questions(source_ref);
  CREATE INDEX IF NOT EXISTS epaper_questions_paper ON epaper_questions(paper_key, paper_seq);

  CREATE TABLE IF NOT EXISTS epaper_mark_points (   -- rows only for question_type = 'oeq'
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    question_id INTEGER NOT NULL REFERENCES epaper_questions(id),
    seq         INTEGER NOT NULL,
    point_kind  TEXT NOT NULL,   -- keyword | textual_evidence | inference | multi_part
    description TEXT NOT NULL DEFAULT '',
    keywords    TEXT NOT NULL DEFAULT ''   -- JSON [[a,b],[c]] = (a OR b) AND c
  );
  CREATE INDEX IF NOT EXISTS epaper_mark_points_q ON epaper_mark_points(question_id);

  CREATE TABLE IF NOT EXISTS epaper_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    mode         TEXT NOT NULL DEFAULT 'paper',  -- 'paper' | 'mistakes'
    paper_key    TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'in_progress', -- in_progress -> reviewed (no oeq items)
                                                          -- or -> pending_review -> reviewed
    score_earned INTEGER,
    marks_total  INTEGER,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    reviewed_at  TEXT
  );

  CREATE TABLE IF NOT EXISTS epaper_session_items (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id     INTEGER NOT NULL REFERENCES epaper_sessions(id),
    question_id    INTEGER NOT NULL REFERENCES epaper_questions(id),
    seq            INTEGER NOT NULL,
    answer         TEXT,
    auto_correct   INTEGER,   -- mcq/fill_blank only, set at submit; NULL for oeq items
    final_correct  INTEGER    -- mcq/fill_blank only; defaults to auto_correct, parent can flip
  );
  CREATE INDEX IF NOT EXISTS epaper_session_items_s ON epaper_session_items(session_id);

  CREATE TABLE IF NOT EXISTS epaper_item_points (   -- rows only for oeq items
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id       INTEGER NOT NULL REFERENCES epaper_session_items(id),
    mark_point_id INTEGER NOT NULL REFERENCES epaper_mark_points(id),
    auto_hit      INTEGER NOT NULL DEFAULT 0,
    final_hit     INTEGER      -- NULL until reviewed; then 0/1
  );
  CREATE INDEX IF NOT EXISTS epaper_item_points_i ON epaper_item_points(item_id);
```

- [ ] **Step 3: Add `epaper` to the audit-log path regex**

Change line 732 from:
```js
const AUDIT_PATHS = /^\/api\/(stamps|unlock|tasks|vocab|dictation|dictation-lists|english|science)(\/|$)/;
```
to:
```js
const AUDIT_PATHS = /^\/api\/(stamps|unlock|tasks|vocab|dictation|dictation-lists|english|science|epaper)(\/|$)/;
```

- [ ] **Step 4: Verify syntax and a clean boot**

```bash
node --check backend/server.js
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db ".tables" | tr -s ' ' '\n' | grep epaper
kill %1
```

Expected: `node --check` prints nothing (success); the `.tables` output lists all five
`epaper_*` tables.

- [ ] **Step 5: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper_* schema for the English Paper 2 practice module

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Backend grading + scoring helpers

**Files:**
- Modify: `backend/server.js` (add functions right after `scienceAutoHit`, ~line 810)
- Test: manual, via a short throwaway Node script (no test framework in this repo — see
  Global Constraints; every other backend task in `tools/science-oeq/` was verified the
  same way)

**Interfaces:**
- Consumes: `normalizeEnglishAnswer(s)`, `scienceParse(json, fallback)`,
  `scienceGroupHit(text, group)` — all already defined in `server.js`, all generic (none
  reference a science-only column), reused verbatim rather than duplicated.
- Produces: `epaperGradeObjective(answer, correctAnswer) -> boolean`,
  `epaperAutoHit(markPoint, answer) -> boolean`,
  `epaperComputeScore(db, sessionId) -> { marksTotal, scoreEarned }` — Task 4/5/7 call these
  by exact name.

- [ ] **Step 1: Add the grading + scoring helpers**

Insert right after the `scienceAutoHit` function (backend/server.js, ~line 810):

```js
// ------------------------------------------------------- 英语试卷 grading/scoring
// mcq/fill_blank: identical rule to the existing English wrong-answer bank —
// "alt1 / alt2" in correct_answer means either counts, compared after the
// same normalization (lowercase, collapsed whitespace, stripped punctuation).
function epaperGradeObjective(answer, correctAnswer) {
  const alts = String(correctAnswer || "").split("/").map((a) => normalizeEnglishAnswer(a));
  return alts.includes(normalizeEnglishAnswer(answer));
}

// oeq: the exact same AND-of-ORs keyword matcher as science, minus any_of/
// need_n (not needed for this module's "Any two of..." style — English
// comprehension mark schemes tested so far don't use that pattern; add it
// back symmetrically with science if a later paper needs it).
function epaperAutoHit(markPoint, answer) {
  const text = normalizeEnglishAnswer(answer);
  const groups = scienceParse(markPoint.keywords, []);
  return groups.every((g) => scienceGroupHit(text, g));
}

// Always recomputed from current DB state, never incremented by hand — so
// there is no drift between what's stored on epaper_sessions and what the
// items/points actually say. Called at both complete and review.
function epaperComputeScore(db, sessionId) {
  const items = db.prepare(`
    SELECT i.id, i.final_correct, q.marks, q.question_type
      FROM epaper_session_items i JOIN epaper_questions q ON q.id = i.question_id
     WHERE i.session_id = ?`).all(sessionId);
  let marksTotal = 0, scoreEarned = 0;
  for (const it of items) {
    marksTotal += it.marks;
    if (it.question_type === "oeq") {
      const pts = db.prepare(
        "SELECT auto_hit, final_hit FROM epaper_item_points WHERE item_id = ?"
      ).all(it.id);
      scoreEarned += pts.reduce((s, p) => s + (p.final_hit !== null ? p.final_hit : p.auto_hit), 0);
    } else {
      scoreEarned += it.final_correct ? it.marks : 0;
    }
  }
  return { marksTotal, scoreEarned };
}
```

- [ ] **Step 2: Smoke-test the pure functions in isolation**

```bash
node -e '
const { DatabaseSync } = require("node:sqlite");
// Re-declare the three functions here verbatim is wasteful; instead require
// server.js is not possible (it boots an http server as a side effect), so
// this step just checks the two pure functions by eye against known inputs —
// copy them into a scratch file to run standalone:
'
cat > /tmp/epaper-grade-check.js << 'EOF'
function normalizeEnglishAnswer(s) {
  return String(s || "").trim().toLowerCase().replace(/\s+/g, " ").replace(/[.,!?;:"'()]/g, "").trim();
}
function scienceParse(json, fallback) { try { return JSON.parse(json); } catch { return fallback; } }
function scienceGroupHit(text, group) { return group.some((term) => text.includes(normalizeEnglishAnswer(term))); }
function epaperGradeObjective(answer, correctAnswer) {
  const alts = String(correctAnswer || "").split("/").map((a) => normalizeEnglishAnswer(a));
  return alts.includes(normalizeEnglishAnswer(answer));
}
function epaperAutoHit(markPoint, answer) {
  const text = normalizeEnglishAnswer(answer);
  const groups = scienceParse(markPoint.keywords, []);
  return groups.every((g) => scienceGroupHit(text, g));
}
console.assert(epaperGradeObjective("were", "was / were") === true, "alt match failed");
console.assert(epaperGradeObjective("Were.", "was / were") === true, "punctuation/case failed");
console.assert(epaperGradeObjective("is", "was / were") === false, "false positive");
console.assert(epaperAutoHit({ keywords: '[["refuge","shelter"]]' }, "it was their refuge") === true, "keyword miss");
console.assert(epaperAutoHit({ keywords: '[["refuge"],["quiet"]]' }, "it was their refuge") === false, "AND-group should fail without both");
console.log("all epaper grading assertions passed");
EOF
node /tmp/epaper-grade-check.js
```

Expected: `all epaper grading assertions passed`, no assertion output before it.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper grading and score-recompute helpers

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: API — papers list, session create, image route

**Files:**
- Modify: `backend/server.js` (insert route block right after the science routes, before
  line 2060's `sendJSON(404, ...)` fallthrough)

**Interfaces:**
- Consumes: `EPAPER_IMAGES_DIR` (Task 1), schema tables (Task 1).
- Produces: `GET /api/epaper/papers`, `POST /api/epaper/sessions`, `GET
  /epaper-images/:file` — Task 14 (APIClient.swift) calls these by exact path and body
  shape below.

- [ ] **Step 1: Add the three routes**

Insert before the final `sendJSON(404, { error: "not found" });` (backend/server.js:2060):

```js
    // ================================================== 英语试卷 (English Paper 2) ==

    // --- question images (open; same 3-layer traversal guard as science-images) --
    if (method === "GET" && pathname.startsWith("/epaper-images/")) {
      const file = path.basename(pathname);
      const full = path.join(EPAPER_IMAGES_DIR, file);
      if (!full.startsWith(EPAPER_IMAGES_DIR) || !/^[\w.-]+\.png$/.test(file) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "image not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- list papers for the browse screen (open; the kid app calls this) --------
    if (method === "GET" && pathname === "/api/epaper/papers") {
      const papers = db.prepare(`
        SELECT paper_key AS paperKey, school, year,
               COUNT(*) AS questionCount, SUM(marks) AS marksTotal
          FROM epaper_questions WHERE paper_key != ''
         GROUP BY paper_key ORDER BY year DESC, school ASC`).all();
      const mistakeCount = db.prepare("SELECT COUNT(*) n FROM epaper_questions WHERE in_mistake_bank = 1").get().n;
      return sendJSON(200, { papers, mistakeCount });
    }

    // --- start a practice set (open; the kid app calls this) ---------------------
    if (method === "POST" && pathname === "/api/epaper/sessions") {
      const body = await readBody(req);
      const paperKey = String(body.paperKey || "");
      const mistakesMode = body.mistakes === true;
      let qids, mode;
      if (paperKey) {
        const rows = db.prepare(
          "SELECT id FROM epaper_questions WHERE paper_key = ? ORDER BY paper_seq ASC"
        ).all(paperKey);
        if (!rows.length) return sendJSON(404, { error: "paper not found" });
        qids = rows.map((r) => r.id);
        mode = "paper";
      } else if (mistakesMode) {
        const rows = db.prepare("SELECT id FROM epaper_questions WHERE in_mistake_bank = 1").all();
        if (!rows.length) return sendJSON(400, { error: "错题本是空的，继续保持！" });
        qids = rows.map((r) => r.id);
        for (let i = qids.length - 1; i > 0; i--) {   // Fisher-Yates
          const j = Math.floor(Math.random() * (i + 1));
          [qids[i], qids[j]] = [qids[j], qids[i]];
        }
        mode = "mistakes";
      } else {
        return sendJSON(400, { error: "paperKey or mistakes is required" });
      }

      const sessionId = db.prepare("INSERT INTO epaper_sessions (mode, paper_key) VALUES (?, ?)")
        .run(mode, paperKey).lastInsertRowid;
      const items = [];
      qids.forEach((qid, idx) => {
        const itemId = db.prepare(
          "INSERT INTO epaper_session_items (session_id, question_id, seq) VALUES (?, ?, ?)"
        ).run(sessionId, qid, idx + 1).lastInsertRowid;
        const q = db.prepare("SELECT * FROM epaper_questions WHERE id = ?").get(qid);
        items.push({
          itemId: Number(itemId), seq: idx + 1, questionId: qid, section: q.section,
          questionType: q.question_type, context: q.context, prompt: q.prompt,
          options: q.options ? JSON.parse(q.options) : null, marks: q.marks, image: q.image,
        });
      });
      // correct_answer/explanation deliberately withheld until submit, same as
      // science withholds model_answer.
      return sendJSON(201, { sessionId: Number(sessionId), mode, items });
    }
```

- [ ] **Step 2: Verify against a throwaway DB**

```bash
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,correct_answer,marks) VALUES ('t-q1','t-2025',1,'Test','2025','grammar_mcq','mcq','pick one','a',1);"
curl -s http://127.0.0.1:2099/api/epaper/papers
echo
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-2025"}'
echo
kill %1
```

Expected: the papers call returns `{"papers":[{"paperKey":"t-2025","school":"Test","year":2025,"questionCount":1,"marksTotal":1}],"mistakeCount":0}`;
the sessions call returns `{"sessionId":1,"mode":"paper","items":[{"itemId":1,"seq":1,...,"questionType":"mcq",...}]}`
with no `correct_answer` field present anywhere in the response.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper papers list + session create + image route

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: API — submit answer (both tiers)

**Files:**
- Modify: `backend/server.js` (insert right after the session-create route added in Task 3)

**Interfaces:**
- Consumes: `epaperGradeObjective`, `epaperAutoHit` (Task 2).
- Produces: `POST /api/epaper/sessions/:id/items/:itemId/submit` — response shape consumed
  by Task 15 (`EnglishPaperRunnerView`)'s `EpaperSubmitResult` decode.

- [ ] **Step 1: Add the submit route**

```js
    // --- submit one answer (open) -------------------------------------------
    const epaperSubmit = pathname.match(/^\/api\/epaper\/sessions\/(\d+)\/items\/(\d+)\/submit$/);
    if (epaperSubmit && method === "POST") {
      const sessionId = Number(epaperSubmit[1]), itemId = Number(epaperSubmit[2]);
      const item = db.prepare(
        "SELECT * FROM epaper_session_items WHERE id = ? AND session_id = ?"
      ).get(itemId, sessionId);
      if (!item) return sendJSON(404, { error: "item not found" });
      const body = await readBody(req);
      const answer = String(body.answer || "");
      const q = db.prepare("SELECT * FROM epaper_questions WHERE id = ?").get(item.question_id);

      if (q.question_type === "oeq") {
        const points = db.prepare(
          "SELECT * FROM epaper_mark_points WHERE question_id = ? ORDER BY seq"
        ).all(q.id);
        const already = db.prepare(
          "SELECT COUNT(*) n FROM epaper_item_points WHERE item_id = ?"
        ).get(itemId).n > 0;
        if (!already) {
          for (const p of points) {
            const hit = epaperAutoHit(p, answer) ? 1 : 0;
            db.prepare(
              "INSERT INTO epaper_item_points (item_id, mark_point_id, auto_hit) VALUES (?, ?, ?)"
            ).run(itemId, p.id, hit);
          }
          db.prepare("UPDATE epaper_session_items SET answer = ? WHERE id = ?").run(answer, itemId);
        }
        const hits = db.prepare(
          "SELECT mark_point_id, auto_hit FROM epaper_item_points WHERE item_id = ?"
        ).all(itemId);
        const hitBy = new Map(hits.map((h) => [h.mark_point_id, h.auto_hit]));
        const autoScore = hits.reduce((s, h) => s + h.auto_hit, 0);
        return sendJSON(200, {
          questionType: "oeq", autoScore, marks: q.marks, explanation: q.explanation,
          provisional: true,
          points: points.map((p) => ({
            markPointId: p.id, seq: p.seq, pointKind: p.point_kind,
            description: p.description, autoHit: (hitBy.get(p.id) || 0) === 1,
          })),
        });
      }

      // mcq / fill_blank — objective, instant, non-provisional. Idempotent:
      // re-posting returns the stored verdict instead of re-scoring and
      // double-counting attempts/score_total.
      if (item.final_correct === null) {
        const correct = epaperGradeObjective(answer, q.correct_answer);
        db.prepare(
          "UPDATE epaper_session_items SET answer = ?, auto_correct = ?, final_correct = ? WHERE id = ?"
        ).run(answer, correct ? 1 : 0, correct ? 1 : 0, itemId);
        db.prepare("UPDATE epaper_questions SET attempts = attempts + 1, score_total = score_total + ? WHERE id = ?")
          .run(correct ? q.marks : 0, q.id);
        if (!correct) db.prepare("UPDATE epaper_questions SET in_mistake_bank = 1 WHERE id = ?").run(q.id);
        item.final_correct = correct ? 1 : 0;
      }
      return sendJSON(200, {
        questionType: q.question_type, correct: item.final_correct === 1,
        correctAnswer: q.correct_answer, explanation: q.explanation, marks: q.marks,
        provisional: false,
      });
    }
```

- [ ] **Step 2: Verify both grading paths against a throwaway DB**

```bash
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db "
INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,correct_answer,marks,explanation) VALUES ('t-q1','t-2025',1,'Test','2025','grammar_mcq','mcq','pick one','were',1,'because plural subject');
INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,marks,explanation) VALUES ('t-q2','t-2025',2,'Test','2025','comprehension_oeq','oeq','why?',2,'model answer text');
"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_mark_points (question_id,seq,point_kind,description,keywords) VALUES (2,1,'textual_evidence','quotes the text','[[\"refuge\"]]');"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_mark_points (question_id,seq,point_kind,description,keywords) VALUES (2,2,'inference','explains why','[[\"quiet\",\"peaceful\"]]');"
SID=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-2025"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/1/submit -H 'Content-Type: application/json' -d '{"answer":"Were"}'
echo
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/2/submit -H 'Content-Type: application/json' -d '{"answer":"it was their quiet refuge"}'
echo
kill %1
```

Expected: item 1 returns `{"questionType":"mcq","correct":true,"correctAnswer":"were",...,"provisional":false}`;
item 2 returns `{"questionType":"oeq","autoScore":2,"marks":2,...,"provisional":true,"points":[{"markPointId":1,...,"autoHit":true},{"markPointId":2,...,"autoHit":true}]}`.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper submit — instant objective grading + oeq keyword pre-grade

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: API — complete session

**Files:**
- Modify: `backend/server.js` (insert right after the submit route added in Task 4)

**Interfaces:**
- Consumes: `epaperComputeScore` (Task 2).
- Produces: `POST /api/epaper/sessions/:id/complete`.

- [ ] **Step 1: Add the complete route**

```js
    // --- finish a set: straight to 'reviewed' if no oeq item, else the parent's
    // review queue (open) ------------------------------------------------------
    const epaperComplete = pathname.match(/^\/api\/epaper\/sessions\/(\d+)\/complete$/);
    if (epaperComplete && method === "POST") {
      const sessionId = Number(epaperComplete[1]);
      const session = db.prepare("SELECT id FROM epaper_sessions WHERE id = ?").get(sessionId);
      if (!session) return sendJSON(404, { error: "session not found" });
      const hasOeq = db.prepare(`
        SELECT COUNT(*) n FROM epaper_session_items i
          JOIN epaper_questions q ON q.id = i.question_id
         WHERE i.session_id = ? AND q.question_type = 'oeq'`).get(sessionId).n > 0;
      const { marksTotal, scoreEarned } = epaperComputeScore(db, sessionId);
      const status = hasOeq ? "pending_review" : "reviewed";
      db.prepare(`UPDATE epaper_sessions SET status = ?, completed_at = datetime('now'),
        reviewed_at = CASE WHEN ? THEN reviewed_at ELSE datetime('now') END,
        score_earned = ?, marks_total = ? WHERE id = ?`)
        .run(status, hasOeq ? 1 : 0, scoreEarned, marksTotal, sessionId);
      return sendJSON(200, { ok: true, status, scoreEarned, marksTotal });
    }
```

- [ ] **Step 2: Verify both status branches**

```bash
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,correct_answer,marks) VALUES ('t-q1','t-obj-2025',1,'Test','2025','grammar_mcq','mcq','pick one','were',1);"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,marks) VALUES ('t-q2','t-oeq-2025',1,'Test','2025','comprehension_oeq','oeq','why?',1);"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_mark_points (question_id,seq,point_kind,description,keywords) VALUES (2,1,'keyword','x','[[\"x\"]]');"

SID1=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-obj-2025"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID1/items/1/submit -H 'Content-Type: application/json' -d '{"answer":"were"}' > /dev/null
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID1/complete
echo

SID2=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-oeq-2025"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID2/items/2/submit -H 'Content-Type: application/json' -d '{"answer":"x"}' > /dev/null
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID2/complete
echo
kill %1
```

Expected: the first `complete` call returns `{"ok":true,"status":"reviewed","scoreEarned":1,"marksTotal":1}`;
the second returns `{"ok":true,"status":"pending_review","scoreEarned":1,"marksTotal":1}` (the oeq
auto-hit still counts provisionally toward the displayed score, but the status shows it's not final).

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper session complete — branch reviewed/pending_review by oeq presence

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: API — admin session list + detail

**Files:**
- Modify: `backend/server.js` (insert right after the complete route added in Task 5)

**Interfaces:**
- Produces: `GET /api/epaper/sessions`, `GET /api/epaper/sessions/:id` — Task 17's
  `refreshEpaper()`/`openEpaperGradeDialog()` call these by exact shape.

- [ ] **Step 1: Add both routes**

```js
    // --- session list (admin): full history, not just pending -----------------
    if (method === "GET" && pathname === "/api/epaper/sessions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const status = url.searchParams.get("status");
      const where = status ? "WHERE status = ?" : "";
      const args = status ? [status] : [];
      const rows = db.prepare(`SELECT * FROM epaper_sessions ${where} ORDER BY created_at DESC`).all(...args);
      return sendJSON(200, { sessions: rows });
    }

    // --- one session in full, for the review dialog (admin) --------------------
    const epaperSessDetail = pathname.match(/^\/api\/epaper\/sessions\/(\d+)$/);
    if (epaperSessDetail && method === "GET") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(epaperSessDetail[1]);
      const session = db.prepare("SELECT * FROM epaper_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      const items = db.prepare(`
        SELECT i.*, q.section, q.question_type, q.context, q.prompt, q.options,
               q.correct_answer, q.explanation, q.marks, q.image, q.school, q.year
          FROM epaper_session_items i JOIN epaper_questions q ON q.id = i.question_id
         WHERE i.session_id = ? ORDER BY i.seq`).all(id);
      const detailed = items.map((it) => {
        let points = null;
        if (it.question_type === "oeq") {
          points = db.prepare(`
            SELECT mp.id markPointId, mp.seq, mp.point_kind pointKind, mp.description,
                   ip.auto_hit autoHit, ip.final_hit finalHit
              FROM epaper_mark_points mp
              LEFT JOIN epaper_item_points ip ON ip.mark_point_id = mp.id AND ip.item_id = ?
             WHERE mp.question_id = ? ORDER BY mp.seq`).all(it.id, it.question_id);
        }
        return { ...it, options: it.options ? JSON.parse(it.options) : null, points };
      });
      return sendJSON(200, { session, items: detailed });
    }
```

- [ ] **Step 2: Verify**

```bash
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,correct_answer,marks) VALUES ('t-q1','t-2025',1,'Test','2025','grammar_mcq','mcq','pick one','were',1);"
SID=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-2025"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/1/submit -H 'Content-Type: application/json' -d '{"answer":"were"}' > /dev/null
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/complete > /dev/null
curl -s http://127.0.0.1:2099/api/epaper/sessions -H 'X-Admin-Pin: 1234'
echo
curl -s http://127.0.0.1:2099/api/epaper/sessions/$SID -H 'X-Admin-Pin: 1234'
echo
kill %1
```

Expected: the list call shows the one session with `status:"reviewed"`; the detail call
shows `items[0].question_type == "mcq"`, `items[0].points == null`,
`items[0].final_correct == 1`.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper admin session list + detail

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: API — review (both tiers), mistake-bank PATCH, DELETE session

**Files:**
- Modify: `backend/server.js` (insert right after the routes added in Task 6)

**Interfaces:**
- Consumes: `epaperComputeScore` (Task 2).
- Produces: `POST /api/epaper/sessions/:id/review`, `PATCH /api/epaper/questions/:id`,
  `DELETE /api/epaper/sessions/:id`.

- [ ] **Step 1: Add all three routes**

```js
    // --- parent review: can correct EITHER tier, on ANY completed session ------
    // Not gated to pending_review — an already-reviewed session (including a
    // fully-objective one that never needed review) can be reopened if a
    // parent spots an auto-grading mistake (e.g. an unlisted synonym).
    const epaperReview = pathname.match(/^\/api\/epaper\/sessions\/(\d+)\/review$/);
    if (epaperReview && method === "POST") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const sessionId = Number(epaperReview[1]);
      const session = db.prepare("SELECT * FROM epaper_sessions WHERE id = ?").get(sessionId);
      if (!session) return sendJSON(404, { error: "session not found" });
      const body = await readBody(req);
      if (!Array.isArray(body.items)) return sendJSON(400, { error: "items array required" });
      const alreadyReviewed = session.status === "reviewed";

      for (const entry of body.items) {
        const itemId = Number(entry.itemId);
        const item = db.prepare(
          "SELECT * FROM epaper_session_items WHERE id = ? AND session_id = ?"
        ).get(itemId, sessionId);
        if (!item) continue;
        const q = db.prepare("SELECT * FROM epaper_questions WHERE id = ?").get(item.question_id);

        if (Array.isArray(entry.points)) {
          // oeq: mirrors science's review delta exactly — attempts only
          // increments the FIRST time this session's verdict is finalized.
          const before = db.prepare(
            "SELECT auto_hit, final_hit FROM epaper_item_points WHERE item_id = ?"
          ).all(itemId);
          const prev = before.reduce((s, p) => s + (p.final_hit !== null ? p.final_hit : p.auto_hit), 0);
          let final = 0;
          for (const p of entry.points) {
            const hit = p.hit ? 1 : 0;
            final += hit;
            db.prepare(
              "UPDATE epaper_item_points SET final_hit = ? WHERE item_id = ? AND mark_point_id = ?"
            ).run(hit, itemId, Number(p.markPointId));
          }
          const prevAttempt = alreadyReviewed ? 1 : 0;
          db.prepare("UPDATE epaper_questions SET attempts = attempts + ?, score_total = score_total + ? WHERE id = ?")
            .run(1 - prevAttempt, final - prev, q.id);
          if (final < q.marks) db.prepare("UPDATE epaper_questions SET in_mistake_bank = 1 WHERE id = ?").run(q.id);
        } else if (typeof entry.finalCorrect === "boolean") {
          // objective: a pure correction to what submit already counted once —
          // attempts never changes here, only score_total's delta and the
          // sticky mistake-bank flag.
          const prev = item.final_correct ? q.marks : 0;
          const now = entry.finalCorrect ? q.marks : 0;
          db.prepare("UPDATE epaper_session_items SET final_correct = ? WHERE id = ?")
            .run(entry.finalCorrect ? 1 : 0, itemId);
          db.prepare("UPDATE epaper_questions SET score_total = score_total + ? WHERE id = ?")
            .run(now - prev, q.id);
          if (!entry.finalCorrect) db.prepare("UPDATE epaper_questions SET in_mistake_bank = 1 WHERE id = ?").run(q.id);
        }
      }

      const { marksTotal, scoreEarned } = epaperComputeScore(db, sessionId);
      db.prepare(`UPDATE epaper_sessions SET status = 'reviewed', reviewed_at = datetime('now'),
        score_earned = ?, marks_total = ? WHERE id = ?`).run(scoreEarned, marksTotal, sessionId);
      return sendJSON(200, { ok: true, scoreEarned, marksTotal });
    }

    // --- clear (or set) a question's 错题本 membership (admin only) ------------
    const epaperQuestionMatch = pathname.match(/^\/api\/epaper\/questions\/(\d+)$/);
    if (epaperQuestionMatch && method === "PATCH") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      if (typeof body.inMistakeBank !== "boolean") {
        return sendJSON(400, { error: "inMistakeBank (boolean) is required" });
      }
      const info = db.prepare("UPDATE epaper_questions SET in_mistake_bank = ? WHERE id = ?")
        .run(body.inMistakeBank ? 1 : 0, Number(epaperQuestionMatch[1]));
      if (!info.changes) return sendJSON(404, { error: "question not found" });
      return sendJSON(200, { ok: true });
    }

    // --- delete a session record (admin) ----------------------------------------
    if (epaperSessDetail && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(epaperSessDetail[1]);
      const items = db.prepare("SELECT id FROM epaper_session_items WHERE session_id = ?").all(id);
      for (const it of items) {
        db.prepare("DELETE FROM epaper_item_points WHERE item_id = ?").run(it.id);
      }
      db.prepare("DELETE FROM epaper_session_items WHERE session_id = ?").run(id);
      const info = db.prepare("DELETE FROM epaper_sessions WHERE id = ?").run(id);
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // Also browse the bank directly (admin), mirroring GET /api/science/questions —
    // needed by the mistake-bank management tab.
    if (method === "GET" && pathname === "/api/epaper/questions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const limit = Math.min(200, Math.max(1, parseInt(url.searchParams.get("limit") || "50", 10)));
      const mistakeOnly = url.searchParams.get("mistakeBank") === "1";
      const where = mistakeOnly ? "WHERE in_mistake_bank = 1" : "";
      const total = db.prepare(`SELECT COUNT(*) n FROM epaper_questions ${where}`).get().n;
      const rows = db.prepare(
        `SELECT * FROM epaper_questions ${where} ORDER BY paper_key, paper_seq LIMIT ?`
      ).all(limit);
      return sendJSON(200, { total, questions: rows });
    }
```

Note: `epaperSessDetail` is the same regex-match variable declared in Task 6 — this DELETE
branch must land in the same code region as that `GET` branch (both test `epaperSessDetail`
before checking `method`), exactly mirroring how science's `sciSessDetail` is reused for
both its GET and DELETE handlers.

- [ ] **Step 2: Verify review (both tiers in one call), PATCH, and DELETE**

```bash
rm -f /tmp/epaper-test.db
DB_PATH=/tmp/epaper-test.db PORT=2099 node backend/server.js &
sleep 1
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,correct_answer,marks) VALUES ('t-q1','t-2025',1,'Test','2025','grammar_mcq','mcq','pick one','were',1);"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_questions (source_ref,paper_key,paper_seq,school,year,section,question_type,prompt,marks) VALUES ('t-q2','t-2025',2,'Test','2025','comprehension_oeq','oeq','why?',1);"
sqlite3 /tmp/epaper-test.db "INSERT INTO epaper_mark_points (question_id,seq,point_kind,description,keywords) VALUES (2,1,'keyword','x','[[\"x\"]]');"

SID=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"t-2025"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/1/submit -H 'Content-Type: application/json' -d '{"answer":"is"}' > /dev/null   # wrong on purpose
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/2/submit -H 'Content-Type: application/json' -d '{"answer":"nothing to do with x"}' > /dev/null  # missed the keyword
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/complete > /dev/null

# parent corrects BOTH: flips the mcq to "actually fine" and confirms the oeq point WAS met
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/review -H 'Content-Type: application/json' \
  -d '{"items":[{"itemId":1,"finalCorrect":true},{"itemId":2,"points":[{"markPointId":1,"hit":true}]}]}'
echo
curl -s http://127.0.0.1:2099/api/epaper/sessions/$SID -H 'X-Admin-Pin: 1234' | python3 -m json.tool | grep -A2 '"score_earned"\|"marks_total"'
curl -s http://127.0.0.1:2099/api/epaper/questions -H 'X-Admin-Pin: 1234'
echo
curl -s -X PATCH http://127.0.0.1:2099/api/epaper/questions/2 -H 'X-Admin-Pin: 1234' -H 'Content-Type: application/json' -d '{"inMistakeBank":false}'
echo
curl -s -X DELETE http://127.0.0.1:2099/api/epaper/sessions/$SID -H 'X-Admin-Pin: 1234'
echo
kill %1
```

Expected: the review response is `{"ok":true,"scoreEarned":2,"marksTotal":2}` (both flipped
to correct); the questions list shows `in_mistake_bank:0` for both (the review corrected
both to right, so neither was flagged missed by *this* review — note: item 1's initial
wrong submit already set `in_mistake_bank=1` at submit-time and the sticky rule means a
later correction does NOT auto-clear it either, so if this assertion fails checking for `1`
rather than `0` on question 1, that is *expected* per the sticky rule — verify the PATCH
call successfully clears it to `0` regardless); the PATCH and DELETE calls both return
`{"ok":true}`.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "backend: epaper review (both tiers), mistake-bank clear, session delete

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: `tools/english-papers/validate.py`

**Files:**
- Create: `tools/english-papers/validate.py`
- Test: run against a small fixture JSON created in this task

**Interfaces:**
- Consumes: nothing (standalone script).
- Produces: the JSON schema every extracted question file must satisfy — Tasks 11/12
  (content extraction) and Task 9 (`import.js`) both depend on the exact field names below.

- [ ] **Step 1: Write the schema doc + validator**

```python
#!/usr/bin/env python3
"""Validate an extracted English Paper 2 question JSON before it reaches the DB.

Two grading tiers share one file, distinguished by question_type:
  mcq / fill_blank  -- needs correct_answer (mcq also needs options including it)
  oeq               -- needs mark_points, and marks == len(mark_points), same
                       invariant as tools/science-oeq/validate.py

Usage:
    python3 validate.py aitong-2025-questions.json [--images DIR]
"""
import argparse
import json
import pathlib
import sys
from collections import Counter

SECTIONS = {
    "grammar_mcq", "vocab_mcq", "cloze_mcq", "comprehension_mcq",
    "cloze_wordbank", "editing", "cloze_open", "synthesis", "comprehension_oeq",
}
TYPES = {"mcq", "fill_blank", "oeq"}
KINDS = {"keyword", "textual_evidence", "inference", "multi_part"}


def check_groups(groups, where, errs):
    if not isinstance(groups, list) or not groups:
        errs.append(f"{where}: keyword groups must be a non-empty list")
        return
    for g in groups:
        if not isinstance(g, list) or not g or not all(isinstance(s, str) and s for s in g):
            errs.append(f"{where}: each group must be a non-empty list of strings, got {g!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--images", default="../../backend/epaper-images")
    args = ap.parse_args()

    data = json.loads(pathlib.Path(args.file).read_text())
    qs = data["questions"]
    imgdir = pathlib.Path(args.images)

    errs, warns = [], []
    refs = Counter()
    section_count = Counter()
    total_marks = 0

    for q in qs:
        ref = q.get("source_ref", "<missing>")
        refs[ref] += 1
        section = q.get("section")
        section_count[section] += 1
        if section not in SECTIONS:
            errs.append(f"{ref}: unknown section {section!r}")

        qtype = q.get("question_type")
        if qtype not in TYPES:
            errs.append(f"{ref}: unknown question_type {qtype!r}")

        marks = q.get("marks")
        if not isinstance(marks, int) or marks < 1:
            errs.append(f"{ref}: marks must be a positive int, got {marks!r}")
            marks = 0
        total_marks += marks

        if not q.get("prompt"):
            errs.append(f"{ref}: prompt is required")

        img = q.get("image")
        if img and not (imgdir / img).exists():
            errs.append(f"{ref}: image not found: {imgdir / img}")

        if qtype in ("mcq", "fill_blank"):
            if not q.get("correct_answer"):
                errs.append(f"{ref}: {qtype} needs correct_answer")
            if qtype == "mcq":
                opts = q.get("options")
                if not isinstance(opts, list) or len(opts) < 2:
                    errs.append(f"{ref}: mcq needs options (list of >= 2 strings)")
                else:
                    alts = [a.strip().lower() for a in q["correct_answer"].split("/")]
                    if not any(o.strip().lower() in alts for o in opts):
                        errs.append(f"{ref}: correct_answer {q['correct_answer']!r} not found in options {opts!r}")
            if q.get("mark_points"):
                errs.append(f"{ref}: {qtype} must not carry mark_points")
        elif qtype == "oeq":
            pts = q.get("mark_points", [])
            if len(pts) != marks:
                errs.append(f"{ref}: marks={marks} but {len(pts)} mark_points")
            for p in pts:
                where = f"{ref}#{p.get('seq')}"
                kind = p.get("point_kind")
                if kind not in KINDS:
                    errs.append(f"{where}: unknown point_kind {kind!r}")
                if not p.get("description"):
                    warns.append(f"{where}: no description — the child sees this after answering")
                if "keywords" not in p:
                    errs.append(f"{where}: needs keywords")
                else:
                    check_groups(p["keywords"], where, errs)

    for ref, n in refs.items():
        if n > 1:
            errs.append(f"duplicate source_ref: {ref} x{n}")

    print(f"{len(qs)} question parts, {total_marks} marks total")
    print("\nsection distribution:")
    for k, n in section_count.most_common():
        print(f"  {k:<22}{n}")

    if warns:
        print(f"\n{len(warns)} warning(s):")
        for w in warns:
            print(f"  ! {w}")
    if errs:
        print(f"\n{len(errs)} ERROR(s):")
        for e in errs:
            print(f"  x {e}")
        sys.exit(1)
    print("\nOK — no errors")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write a fixture that must pass, and one that must fail, and check both**

```bash
mkdir -p /tmp/epaper-fixture-ok /tmp/epaper-fixture-bad
cat > /tmp/epaper-fixture-ok/q.json << 'EOF'
{"questions": [
  {"source_ref": "fix-2025-q1", "section": "grammar_mcq", "question_type": "mcq",
   "prompt": "She ___ happy.", "options": ["is", "are", "was", "were"],
   "correct_answer": "is", "marks": 1, "explanation": "singular subject"},
  {"source_ref": "fix-2025-q2", "section": "comprehension_oeq", "question_type": "oeq",
   "prompt": "Why?", "marks": 1,
   "mark_points": [{"seq": 1, "point_kind": "keyword", "description": "names the cause",
                     "keywords": [["refuge"]]}]}
]}
EOF
cat > /tmp/epaper-fixture-bad/q.json << 'EOF'
{"questions": [
  {"source_ref": "fix-2025-q1", "section": "grammar_mcq", "question_type": "mcq",
   "prompt": "She ___ happy.", "options": ["is", "are"],
   "correct_answer": "was", "marks": 1}
]}
EOF
python3 tools/english-papers/validate.py /tmp/epaper-fixture-ok/q.json --images /tmp/epaper-fixture-ok
python3 tools/english-papers/validate.py /tmp/epaper-fixture-bad/q.json --images /tmp/epaper-fixture-bad; echo "exit=$?"
```

Expected: the first call prints `OK — no errors`; the second prints an error containing
`correct_answer 'was' not found in options` and `exit=1`.

- [ ] **Step 3: Commit**

```bash
git add tools/english-papers/validate.py
git commit -m "tools(english-papers): validate.py for the two-tier question schema

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 9: `tools/english-papers/import.js`

**Files:**
- Create: `tools/english-papers/import.js`
- Test: import the same fixture from Task 8 into a throwaway DB

**Interfaces:**
- Consumes: the JSON shape validated by Task 8's `validate.py`.
- Produces: rows in `epaper_questions`/`epaper_mark_points` — Tasks 11/12/13 all run this
  script.

- [ ] **Step 1: Write the importer**

```js
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
      q.section || "", q.question_type, q.context || "", q.prompt,
      q.options ? JSON.stringify(q.options) : null, q.correct_answer || null,
      q.marks, q.image || "", q.explanation || "", paperKey, idx + 1,
    ];

    const existing = db.prepare("SELECT id FROM epaper_questions WHERE source_ref = ?").get(q.source_ref);
    let qid;
    if (existing) {
      // Preserve attempts/score_total/in_mistake_bank — re-importing a fixed
      // keyword list or corrected answer must not wipe the child's history.
      db.prepare(`UPDATE epaper_questions SET school=?, year=?, section=?, question_type=?,
        context=?, prompt=?, options=?, correct_answer=?, marks=?, image=?, explanation=?,
        paper_key=?, paper_seq=? WHERE source_ref=?`)
        .run(...row, q.source_ref);
      qid = existing.id;
      updated++;
    } else {
      qid = db.prepare(`INSERT INTO epaper_questions
        (school, year, section, question_type, context, prompt, options, correct_answer,
         marks, image, explanation, paper_key, paper_seq, source_ref)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(...row, q.source_ref).lastInsertRowid;
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
```

- [ ] **Step 2: Dry-run and real-run against a throwaway DB using Task 8's fixture**

```bash
rm -f /tmp/epaper-import-test.db
DB_PATH=/tmp/epaper-import-test.db node tools/english-papers/import.js /tmp/epaper-fixture-ok/q.json --dry-run
DB_PATH=/tmp/epaper-import-test.db node tools/english-papers/import.js /tmp/epaper-fixture-ok/q.json
sqlite3 /tmp/epaper-import-test.db "SELECT source_ref, question_type, marks FROM epaper_questions;"
sqlite3 /tmp/epaper-import-test.db "SELECT question_id, point_kind FROM epaper_mark_points;"
# re-run to confirm idempotency (updated, not duplicated)
DB_PATH=/tmp/epaper-import-test.db node tools/english-papers/import.js /tmp/epaper-fixture-ok/q.json
sqlite3 /tmp/epaper-import-test.db "SELECT COUNT(*) FROM epaper_questions;"
```

Expected: dry-run prints `(dry run — rolled back)` and does not create rows (verify by
running the same `SELECT COUNT(*)` before the real run, expecting 0); the real run inserts
2 questions and 1 mark point; the re-run reports `updated=2 inserted=0` and the row count
stays at 2 (no duplicates).

- [ ] **Step 3: Commit**

```bash
git add tools/english-papers/import.js
git commit -m "tools(english-papers): import.js — idempotent bulk loader into epaper_*

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 10: `.gitignore` — exclude English-paper content

**Files:**
- Modify: `.gitignore`

**Interfaces:** none (config only).

- [ ] **Step 1: Add the exclusion rules, mirroring the science-oeq block**

Check the existing science-oeq block first:

```bash
grep -n "science-oeq" .gitignore
```

Add a parallel block right after it:

```
# English Paper 2 practice module (tools/english-papers/) — same discipline as
# science-oeq: source PDFs, page renders, and extracted question JSON are
# other schools' copyrighted material plus a real child's schoolwork. Only
# the tooling and crop-config page-maps are committed.
tools/english-papers/papers/
tools/english-papers/survey/
tools/english-papers/*-questions.json
backend/epaper-images/
```

- [ ] **Step 2: Verify the already-downloaded papers are now ignored**

```bash
git status --porcelain tools/english-papers/ | head
```

Expected: no output (the `papers/` directory, already containing the 14 downloaded PDFs
from before this plan started, does not show up as untracked).

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "gitignore: exclude English-paper source/extracted content, same as science-oeq

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 11: Content — Ai Tong 2025 Paper 2 extraction + import

**Files:**
- Create: `tools/english-papers/aitong-2025-questions.json` (gitignored)
- Create: `tools/english-papers/aitong.crop.json` (committed)
- Uses: `tools/science-oeq/crop_questions.py --config` (already generalized to accept any
  paper/slug/question_pages — no code change needed, confirmed by its existing
  `DEFAULT_CONFIG` fallback design)

**Interfaces:**
- Consumes: the schema Task 8 validates and Task 9 imports.
- Produces: ~75 rows in `epaper_questions` for `paper_key = 'aitong-2025'`.

This is content authoring, not code — the shape is fixed by Task 8/9; what's produced here
is the actual transcription of `tools/english-papers/papers/2025-english-aitong.pdf`
(pages 6–22, per the earlier read-through: page 6 starts Booklet A Q1, page 22 ends Booklet
B Q75 — composition and the answer-key pages at the end are excluded from `paper_seq`
entirely, they are only *read from*, never imported as questions).

- [ ] **Step 1: Render every Booklet A + B page as PNG for transcription**

```python
import fitz, pathlib
d = fitz.open("tools/english-papers/papers/2025-english-aitong.pdf")
out = pathlib.Path("tools/english-papers/survey/aitong")
out.mkdir(parents=True, exist_ok=True)
for i in range(5, 22):   # 0-based indices for 1-based pages 6-22
    d[i].get_pixmap(dpi=120).save(out / f"p{i+1:03d}.png")
```

- [ ] **Step 2: Transcribe all 75 questions into JSON, following this exact shape**

One fully worked example per grading tier (from the pages already read in this session —
Ai Tong page 6 Q1, page 16 Q26, page 17 Q36, and the Q66 comprehension question whose
answer key appears on the paper's own final answer-key pages):

```json
{
  "_source": "Ai Tong School P6 English Paper 2 2025",
  "questions": [
    {
      "source_ref": "aitong-2025-q1", "section": "grammar_mcq", "question_type": "mcq",
      "prompt": "The family had come to a decision ___ whether to proceed with the operation for their ailing father.",
      "options": ["in", "on", "for", "with"], "correct_answer": "on", "marks": 1,
      "explanation": "\"decision on\" is the fixed preposition pairing."
    },
    {
      "source_ref": "aitong-2025-q26", "section": "cloze_wordbank", "question_type": "fill_blank",
      "context": "Nestled within the Mandai Wildlife Reserve are renowned zoological parks such as Singapore Zoo, Night Safari, River Wonders and Bird Paradise. Managed ___ (26) Mandai Wildlife Group, these parks are home to more...",
      "prompt": "Blank (26): choose the most suitable lettered word from the word bank.",
      "correct_answer": "by", "marks": 1, "explanation": "\"managed by\" — passive voice agent."
    },
    {
      "source_ref": "aitong-2025-q36", "section": "editing", "question_type": "fill_blank",
      "context": "Sylvia was scrolling through social media on her mobile phone one night.",
      "prompt": "The underlined word contains a spelling or grammatical error. Write the correct word.",
      "correct_answer": "Received", "marks": 1, "explanation": "\"reciefed\" is a spelling error for \"received\"."
    },
    {
      "source_ref": "aitong-2025-q68", "section": "comprehension_oeq", "question_type": "oeq",
      "context": "Refer to the void-deck passage used for questions 66-75.",
      "prompt": "Explain clearly why there was 'muffled weeping' (line 18).",
      "marks": 2,
      "mark_points": [
        {"seq": 1, "point_kind": "textual_evidence", "description": "names the occasion — a funeral",
         "keywords": [["funeral"]]},
        {"seq": 2, "point_kind": "inference", "description": "explains the sadness of the occasion",
         "keywords": [["sad","grief","sorrow"]]}
      ]
    }
  ]
}
```

Continue this pattern for every one of the 75 questions read from
`tools/english-papers/survey/aitong/p*.png` (Booklet A: `grammar_mcq` x10, `vocab_mcq` x5,
`cloze_mcq` x5, `comprehension_mcq` x5; Booklet B: `cloze_wordbank` x10, `editing` x10,
`cloze_open` x15, `synthesis` x5, `comprehension_oeq` x10) and the paper's own bundled
answer key (the same PDF's final pages, already confirmed to exist and be readable) for
every `correct_answer`/`explanation`/mark-point value. Cross-check the running mark total
against the paper's own printed totals (Booklet A: 25, Booklet B: 65 — 90 marks total)
exactly as `tools/science-oeq/*-questions.json` cross-validated against each paper's own
Booklet B total.

- [ ] **Step 3: Crop the one image this paper needs (the Booklet A comprehension-MCQ poster)**

```json
{
  "paper": "tools/english-papers/papers/2025-english-aitong.pdf",
  "slug": "aitong-2025",
  "question_pages": {"21": [10]}
}
```
(Adjust the page number to match wherever the "NOVA — The Future in Your Hands" poster
actually renders once Step 1's PNGs are reviewed; `10` was its 1-based PDF page per the
earlier read-through of this file.)

`crop_questions.py`'s only flags are `--config`, `--out` (default
`../../backend/science-images`), `--dpi` (default 150) — there is no `--prefix`; the output
filename is always `{slug}-q{key}{suffix}.png`, derived from the config's own `slug` and
the `question_pages` object's keys. With the config above this produces exactly
`aitong-2025-q21.png`:

```bash
python3 tools/science-oeq/crop_questions.py --config tools/english-papers/aitong.crop.json \
  --out backend/epaper-images/
open backend/epaper-images/aitong-2025-q21.png   # eyeball it — CLIP was tuned for
                                                   # science's Booklet-B layout, not an
                                                   # English poster's margins, so confirm
                                                   # the crop actually frames the poster
                                                   # before trusting it; adjust --dpi or
                                                   # the page number in the config if not
```

Reference this same `aitong-2025-q21.png` filename from the `image` field of every
question object that shares this poster (Q21 through Q25) in Step 2's JSON — nothing
requires a 1:1 image-per-question mapping.

- [ ] **Step 4: Validate, dry-run import, then real import into a throwaway DB**

```bash
python3 tools/english-papers/validate.py tools/english-papers/aitong-2025-questions.json --images backend/epaper-images
rm -f /tmp/epaper-content-test.db
DB_PATH=/tmp/epaper-content-test.db node tools/english-papers/import.js tools/english-papers/aitong-2025-questions.json --dry-run
DB_PATH=/tmp/epaper-content-test.db node tools/english-papers/import.js tools/english-papers/aitong-2025-questions.json
```

Expected: `validate.py` prints `OK — no errors` and a mark total of 90; the import reports
`inserted=75 updated=0 skipped=0`.

- [ ] **Step 5: Commit the crop config only (content is gitignored)**

```bash
git add tools/english-papers/aitong.crop.json
git commit -m "tools(english-papers): crop config for Ai Tong 2025

Content itself (aitong-2025-questions.json, page renders) is gitignored —
other schools' copyrighted material plus a real child's schoolwork.

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 12: Content — Catholic High 2025 Paper 2 extraction + import

**Files:**
- Create: `tools/english-papers/catholichigh-2025-questions.json` (gitignored)
- Create: `tools/english-papers/catholichigh.crop.json` (committed)

**Interfaces:**
- Consumes: the schema Task 8 validates and Task 9 imports (same as Task 11).
- Produces: ~75 rows in `epaper_questions` for `paper_key = 'catholichigh-2025'`.

Catholic High's PDF has already been read in full in this session (pages 4–22 are Booklet
A+B; pages 24-25 are the bundled answer key with every one of the 75 answers spelled out,
including the comprehension OEQ model answers) — this paper needs no further page
rendering before transcription can start, unlike Ai Tong.

- [ ] **Step 1: Transcribe all 75 questions, following the exact same JSON shape as Task 11**

Worked example for this paper specifically (from the pages already read this session):

```json
{
  "_source": "Catholic High School P6 English Paper 2 2025",
  "questions": [
    {
      "source_ref": "catholichigh-2025-q1", "section": "grammar_mcq", "question_type": "mcq",
      "prompt": "The feedback provided by our English Language teacher yesterday ___ very useful and helped us to improve on our writing.",
      "options": ["was", "were", "has been", "have been"], "correct_answer": "was", "marks": 1,
      "explanation": "singular subject \"feedback\"."
    },
    {
      "source_ref": "catholichigh-2025-q61", "section": "synthesis", "question_type": "fill_blank",
      "prompt": "Rewrite using \"whose\": Mrs Ramu invited the musician to perform. His song became a hit.",
      "correct_answer": "Mrs Ramu invited the musician whose song became a hit.", "marks": 2,
      "explanation": "relative clause combining the two sentences."
    },
    {
      "source_ref": "catholichigh-2025-q70", "section": "comprehension_oeq", "question_type": "oeq",
      "context": "Refer to the hawker-stall passage used for questions 66-75.",
      "prompt": "Explain what the author meant by 'so I took a risk' (line 22) when he was choosing the cane.",
      "marks": 2,
      "mark_points": [
        {"seq": 1, "point_kind": "textual_evidence", "description": "names what made it uncertain — he could not know it would work",
         "keywords": [["did not know","unsure","uncertain"]]},
        {"seq": 2, "point_kind": "inference", "description": "explains the possible bad outcome he accepted",
         "keywords": [["fail","wrong","hurt"]]}
      ]
    }
  ]
}
```

Continue for all 75 questions, using the answer key already read on pages 24-25 of
`tools/english-papers/papers/2025-english-catholichigh.pdf` for every `correct_answer`,
and Booklet B's own comprehension-question wording (page 21-22) for the oeq mark-point
descriptions. Cross-check against the paper's own printed totals: Booklet A 25 marks,
Booklet B 65 marks, 90 total.

- [ ] **Step 2: Crop the one image this paper needs**

```json
{
  "paper": "tools/english-papers/papers/2025-english-catholichigh.pdf",
  "slug": "catholichigh-2025",
  "question_pages": {"21": [10]}
}
```
(The "Chocolate: The Delicious Superfood" poster, confirmed on page 10 of this PDF earlier
in this session.)

```bash
python3 tools/science-oeq/crop_questions.py --config tools/english-papers/catholichigh.crop.json \
  --out backend/epaper-images/
open backend/epaper-images/catholichigh-2025-q21.png   # eyeball the crop before trusting it,
                                                          # same caveat as Ai Tong's Step 3
```

Reference `catholichigh-2025-q21.png` from every question (Q21-Q25) that shares this poster.

- [ ] **Step 3: Validate, dry-run import, then real import**

```bash
python3 tools/english-papers/validate.py tools/english-papers/catholichigh-2025-questions.json --images backend/epaper-images
DB_PATH=/tmp/epaper-content-test.db node tools/english-papers/import.js tools/english-papers/catholichigh-2025-questions.json --dry-run
DB_PATH=/tmp/epaper-content-test.db node tools/english-papers/import.js tools/english-papers/catholichigh-2025-questions.json
sqlite3 /tmp/epaper-content-test.db "SELECT paper_key, COUNT(*), SUM(marks) FROM epaper_questions GROUP BY paper_key;"
```

Expected: `validate.py` reports 90 marks total, no errors; the DB now shows two paper_keys
(`aitong-2025`, `catholichigh-2025`), each with 75 questions / 90 marks.

- [ ] **Step 4: Commit the crop config only**

```bash
git add tools/english-papers/catholichigh.crop.json
git commit -m "tools(english-papers): crop config for Catholic High 2025

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 13: End-to-end backend smoke test on the real pilot content

**Files:** none created — verification only, against the throwaway DB from Tasks 11/12.

**Interfaces:** exercises every route from Tasks 3-7 against real (not fixture) content.

- [ ] **Step 1: Boot the server on the throwaway DB with both papers imported**

```bash
PORT=2099 DB_PATH=/tmp/epaper-content-test.db node backend/server.js &
sleep 1
curl -s http://127.0.0.1:2099/api/epaper/papers | python3 -m json.tool
```

Expected: two papers listed, `aitong-2025` and `catholichigh-2025`, each `questionCount:75
marksTotal:90`.

- [ ] **Step 2: Play through one paper start to finish, mixing right and wrong answers**

```bash
SID=$(curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"paperKey":"aitong-2025"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sessionId"]); [print(i["itemId"],i["questionType"],file=__import__("sys").stderr) for i in d["items"][:3]]')
# Submit the first mcq item wrong on purpose, to populate the mistake bank:
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/items/1/submit -H 'Content-Type: application/json' -d '{"answer":"definitely wrong"}'
echo
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions/$SID/complete
echo
```

- [ ] **Step 3: Confirm the wrong answer landed in the mistake bank, then start a mistakes session**

```bash
curl -s "http://127.0.0.1:2099/api/epaper/questions?mistakeBank=1" -H 'X-Admin-Pin: 1234' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))'
curl -s -X POST http://127.0.0.1:2099/api/epaper/sessions -H 'Content-Type: application/json' -d '{"mistakes":true}'
echo
kill %1
```

Expected: the mistake-bank query returns at least 1; the mistakes session starts
successfully with that question in it, in `mode:"mistakes"`.

- [ ] **Step 4: No commit** (verification only, nothing new is created)

---

### Task 14: macOS Models.swift + APIClient.swift additions

**Files:**
- Modify: `macos-app/Sources/KidReminder/Models.swift` (append after the science models,
  ~line 316)
- Modify: `macos-app/Sources/KidReminder/APIClient.swift` (append after the science methods,
  ~line 366)

**Interfaces:**
- Consumes: the exact JSON field names from Tasks 3-5's API responses.
- Produces: `EpaperSource`, `EpaperSessionItem`, `EpaperSession`, `EpaperMarkPointResult`,
  `EpaperSubmitResult`, `EpaperPaper`, `EpaperPapersResponse` — Task 15/16 (the two new
  views) consume these by exact type/property name.

- [ ] **Step 1: Append the models**

```swift
// MARK: 英语试卷 (PSLE English Paper 2 — every question, two grading tiers)

/// Where a practice set gets its questions from — mirrors ScienceSource exactly.
enum EpaperSource: Identifiable, Equatable, Codable, Hashable {
    case paper(key: String, title: String)
    case mistakes

    var id: String {
        switch self {
        case .paper(let key, _): return "epaper-\(key)"
        case .mistakes: return "epaper-mistakes"
        }
    }

    var title: String {
        switch self {
        case .paper(_, let title): return title
        case .mistakes: return "📕 错题本"
        }
    }
}

struct EpaperSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let section: String
    let questionType: String   // "mcq" | "fill_blank" | "oeq"
    let context: String
    let prompt: String
    let options: [String]?     // mcq only
    let marks: Int
    let image: String
    var id: Int { itemId }
}

struct EpaperSession: Codable {
    let sessionId: Int
    let items: [EpaperSessionItem]
}

struct EpaperMarkPointResult: Codable, Equatable, Identifiable {
    let markPointId: Int
    let seq: Int
    let pointKind: String
    let description: String
    let autoHit: Bool
    var id: Int { markPointId }
}

/// mcq/fill_blank fill `correct`/`correctAnswer` and leave `points`/`autoScore`
/// nil; oeq is the reverse — the two tiers never populate both halves.
struct EpaperSubmitResult: Codable, Equatable {
    let questionType: String
    let correct: Bool?
    let correctAnswer: String?
    let explanation: String
    let autoScore: Int?
    let marks: Int
    let provisional: Bool
    let points: [EpaperMarkPointResult]?
}

struct EpaperPaper: Codable, Identifiable {
    let paperKey: String
    let school: String
    let year: Int?
    let questionCount: Int
    let marksTotal: Int
    var id: String { paperKey }
}

struct EpaperPapersResponse: Codable {
    let papers: [EpaperPaper]
    let mistakeCount: Int
}
```

- [ ] **Step 2: Append the API client methods**

```swift
    // MARK: - 英语试卷 (English Paper 2, every question)
    //
    // Same shape as the 科学 client methods: browse papers, play start to
    // finish, or drill 错题本. Grading/review lives in the web admin.

    func epaperPapers() async throws -> EpaperPapersResponse {
        let data = try await request("/api/epaper/papers")
        return try JSONDecoder().decode(EpaperPapersResponse.self, from: data)
    }

    func startEpaperSession(paper: String? = nil, mistakes: Bool = false) async throws -> EpaperSession {
        struct Req: Encodable { let paperKey: String?; let mistakes: Bool? }
        let body = try JSONEncoder().encode(Req(paperKey: paper, mistakes: mistakes ? true : nil))
        let data = try await request("/api/epaper/sessions", method: "POST", body: body)
        return try JSONDecoder().decode(EpaperSession.self, from: data)
    }

    func submitEpaperAnswer(sessionId: Int, itemId: Int, answer: String) async throws -> EpaperSubmitResult {
        struct Req: Encodable { let answer: String }
        let body = try JSONEncoder().encode(Req(answer: answer))
        let data = try await request("/api/epaper/sessions/\(sessionId)/items/\(itemId)/submit",
                                     method: "POST", body: body)
        return try JSONDecoder().decode(EpaperSubmitResult.self, from: data)
    }

    func completeEpaperSession(sessionId: Int) async throws {
        _ = try await request("/api/epaper/sessions/\(sessionId)/complete", method: "POST", body: Data("{}".utf8))
    }

    func epaperImageURL(_ file: String) -> URL? {
        guard !file.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = settings.host
        comps.port = settings.port
        comps.path = "/epaper-images/\(file)"
        return comps.url
    }
```

- [ ] **Step 3: Verify it compiles**

```bash
cd macos-app && swift build 2>&1 | tail -30
```

Expected: builds with no errors (warnings about unrelated existing code are fine; any
error mentioning `Epaper` means a typo to fix before proceeding).

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/Models.swift macos-app/Sources/KidReminder/APIClient.swift
git commit -m "macos-app: epaper models + API client methods

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 15: macOS `EnglishPaperPracticeView.swift` + `EnglishPaperRunnerView.swift`

**Files:**
- Create: `macos-app/Sources/KidReminder/EnglishPaperPracticeView.swift`
- Create: `macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift`

**Interfaces:**
- Consumes: `EpaperSource`, `EpaperSession`, `EpaperSessionItem`, `EpaperSubmitResult`,
  `EpaperPapersResponse` (Task 14); `APIClient.epaperPapers()`, `.startEpaperSession(...)`,
  `.submitEpaperAnswer(...)`, `.completeEpaperSession(...)`, `.epaperImageURL(...)` (Task 14).
- Produces: `EnglishPaperPracticeView` (referenced by Task 16's `ContentView` sidebar case)
  and the `"epaper-runner"` window content (referenced by Task 16's `KidReminderApp`
  `WindowGroup`).

- [ ] **Step 1: Write the practice/browse view**

```swift
import SwiftUI

/// 📘 英语试卷 — the browser screen. Lists exam papers (school + year) the kid
/// can play start to finish, plus a 错题本 entry point. Mirrors
/// SciencePracticeView exactly, including opening the runner as its own
/// top-level window (via openWindow) rather than a sheet, for a real
/// maximize/zoom-capable title bar.
struct EnglishPaperPracticeView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    @State private var papers: [EpaperPaper] = []
    @State private var mistakeCount = 0
    @State private var loading = true
    @State private var loadError: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语试卷")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                body_
            }
            .task { await load() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("📘").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("英语试卷").font(.title3.bold())
                Text("挑一张卷子完整做完，或者复习错题本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openWindow(id: "epaper-runner", value: EpaperSource.mistakes)
            } label: {
                Label(mistakeCount > 0 ? "📕 错题本 (\(mistakeCount))" : "📕 错题本",
                      systemImage: "book.closed.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(mistakeCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var body_: some View {
        if loading {
            centered { ProgressView() }
        } else if let loadError {
            centered {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            }
        } else if papers.isEmpty {
            centered {
                ContentUnavailableView("还没有卷子", systemImage: "doc.text",
                    description: Text("家长还没有导入英语试卷。"))
            }
        } else {
            List(papers) { paper in paperRow(paper) }
                .listStyle(.inset)
        }
    }

    private func paperRow(_ paper: EpaperPaper) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(paper.school) \(paper.year.map(String.init) ?? "")")
                    .font(.subheadline)
                Text("\(paper.questionCount) 题 · \(paper.marksTotal) 分")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let source = EpaperSource.paper(key: paper.paperKey, title: "\(paper.school) \(paper.year.map(String.init) ?? "")")
                openWindow(id: "epaper-runner", value: source)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("完整做这张卷子")
        }
        .padding(.vertical, 2)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await api.epaperPapers()
            papers = r.papers
            mistakeCount = r.mistakeCount
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Write the runner view, branching UI by `questionType`**

```swift
import SwiftUI

/// 📘 The English Paper 2 practice window. Three UI shapes share one screen,
/// picked by item.questionType:
///   mcq         -> tappable option buttons, instant right/wrong
///   fill_blank  -> single-line text field, instant right/wrong
///   oeq         -> multi-line text editor, "submitted" only (parent confirms
///                  later in the web admin) — same bounded-height TextEditor
///                  fix used in ScienceRunnerView, never TextField(axis:
///                  .vertical) in a ScrollView (that combination caused the
///                  original science-module AutoLayout crash).
struct EnglishPaperRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismissWindow) private var dismissWindow
    let source: EpaperSource

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }
    private enum ItemPhase: Equatable {
        case answering
        case graded(EpaperSubmitResult)
    }

    @State private var phase: Phase = .loading
    @State private var itemPhase: ItemPhase = .answering
    @State private var session: EpaperSession?
    @State private var typed = ""
    @State private var pickedOption: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(source.title)
            .frame(minWidth: 1000, minHeight: 740)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("关闭") { dismissWindow() }
                }
            }
            .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading: ProgressView("正在准备…")
        case .running(let i): runningView(index: i)
        case .finishing: ProgressView("正在提交…")
        case .done: doneView()
        case .error(let m):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(m))
                .padding()
        }
    }

    @ViewBuilder
    private func runningView(index: Int) -> some View {
        let items = session?.items ?? []
        if items.indices.contains(index) {
            questionView(item: items[index], index: index, total: items.count)
        } else {
            ProgressView()
        }
    }

    private func questionView(item: EpaperSessionItem, index: Int, total: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            answerColumn(item: item, index: index, total: total)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            if let url = api.epaperImageURL(item.image) {
                Divider()
                imageColumn(url: url)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: index) { itemPhase = .answering; typed = ""; pickedOption = nil }
    }

    private func answerColumn(item: EpaperSessionItem, index: Int, total: Int) -> some View {
        let isLast = index >= total - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(index + 1) 题 / 共 \(total) 题").font(.headline)
                Spacer()
                Text("\(item.marks) 分").font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.context.isEmpty {
                        Text(item.context).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(item.prompt).font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Divider()

            switch itemPhase {
            case .answering: answeringControl(item: item)
            case .graded(let result): gradedPanel(item: item, result: result, isLast: isLast, index: index)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func answeringControl(item: EpaperSessionItem) -> some View {
        switch item.questionType {
        case "mcq":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.options ?? [], id: \.self) { opt in
                    Button {
                        pickedOption = opt
                        Task { await submit(item: item, answer: opt) }
                    } label: {
                        HStack {
                            Text(opt).font(.body)
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        case "fill_blank":
            HStack {
                TextField("填空…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { Task { await submit(item: item, answer: typed) } }
                Button("提交") { Task { await submit(item: item, answer: typed) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        default: // "oeq"
            TextEditor(text: $typed)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 160, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if typed.isEmpty {
                        Text("把答案写在这里…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("⌘↵ 提交").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("提交") { Task { await submit(item: item, answer: typed) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func gradedPanel(item: EpaperSessionItem, result: EpaperSubmitResult, isLast: Bool, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if result.provisional {
                    Text("已提交，等待家长在网页端批改")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Image(systemName: (result.correct ?? false) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle((result.correct ?? false) ? .green : .red)
                        Text((result.correct ?? false) ? "答对了" : "答错了")
                            .font(.headline)
                            .foregroundStyle((result.correct ?? false) ? .green : .red)
                    }
                    if let correctAnswer = result.correctAnswer, !(result.correct ?? true) {
                        Text("正确答案：\(correctAnswer)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !result.explanation.isEmpty {
                    Divider()
                    Text(result.explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxHeight: .infinity)
        HStack {
            Spacer()
            Button(isLast ? "✅ 完成" : "➡️ 下一题") {
                if isLast { Task { await finish() } } else { advance(to: index + 1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func imageColumn(url: URL) -> some View {
        ScrollView {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().frame(height: 160)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
        }
    }

    private func doneView() -> some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("做完啦！").font(.title2).bold()
            Text("选择题、填空题已经批完；问答题交给家长在网页端批改。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { dismissWindow() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start() async {
        phase = .loading
        do {
            let s: EpaperSession
            switch source {
            case .paper(let key, _): s = try await api.startEpaperSession(paper: key)
            case .mistakes: s = try await api.startEpaperSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            itemPhase = .answering
            typed = ""
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func submit(item: EpaperSessionItem, answer: String) async {
        guard let sessionId = session?.sessionId, !answer.isEmpty else { return }
        do {
            let r = try await api.submitEpaperAnswer(sessionId: sessionId, itemId: item.itemId, answer: answer)
            itemPhase = .graded(r)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func advance(to index: Int) {
        itemPhase = .answering
        typed = ""
        pickedOption = nil
        phase = .running(index: index)
    }

    private func finish() async {
        guard let sessionId = session?.sessionId else { return }
        phase = .finishing
        do {
            try await api.completeEpaperSession(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
cd macos-app && swift build 2>&1 | tail -40
```

Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/EnglishPaperPracticeView.swift macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift
git commit -m "macos-app: EnglishPaperPracticeView + EnglishPaperRunnerView

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 16: macOS wiring — `KidReminderApp.swift` window group + `ContentView.swift` sidebar

**Files:**
- Modify: `macos-app/Sources/KidReminder/KidReminderApp.swift`
- Modify: `macos-app/Sources/KidReminder/ContentView.swift`
- Modify: `macos-app/build.sh:77` (bump `CFBundleShortVersionString`)

**Interfaces:**
- Consumes: `EpaperSource` (Task 14), `EnglishPaperPracticeView`/`EnglishPaperRunnerView`
  (Task 15).

- [ ] **Step 1: Add the window group**

In `KidReminderApp.swift`, add right after the existing `science-runner` `WindowGroup`
(before the closing `}` of `var body: some Scene`):

```swift
        // 英语试卷 practice — same window-group shape as 科学 (see the comment
        // on the science-runner WindowGroup above for why .contentMinSize,
        // never .defaultSize).
        WindowGroup(id: "epaper-runner", for: EpaperSource.self) { $source in
            if let source {
                NavigationStack {
                    EnglishPaperRunnerView(source: source)
                }
                .environmentObject(settings)
            }
        }
        .windowResizability(.contentMinSize)
```

- [ ] **Step 2: Add the sidebar entry**

In `ContentView.swift`, add a case to `SidebarItem` (after `.science`):

```swift
    case englishPaper = "英语试卷"
```

Add its icon in the `icon` switch:

```swift
        case .englishPaper: return "doc.text.magnifyingglass"
```

Add its detail-view case in `ContentView.body`'s switch (after `.science: SciencePracticeView()`):

```swift
            case .englishPaper: EnglishPaperPracticeView()
```

- [ ] **Step 3: Bump the app version**

```bash
grep -n "CFBundleShortVersionString" macos-app/build.sh
```

Bump the patch version by one from whatever it currently reads (confirmed `1.11.3` as of
this plan being written — verify with the grep above before editing, in case it has moved
since).

- [ ] **Step 4: Build and verify no crash on a plain launch**

```bash
cd macos-app && ./build.sh 2>&1 | tail -20
open build/KidReminder.app
sleep 3
# Confirm no crash report was generated in the last minute:
find ~/Library/Logs/DiagnosticReports -name "KidReminder*" -newer /tmp -mmin -1 2>/dev/null
```

Expected: `build.sh` completes without error; the app opens; the crash-report `find` finds
nothing. Manually click the new "英语试卷" sidebar entry once and confirm the papers list
(or the "还没有卷子"/connection-error placeholder, if not yet pointed at a live backend)
renders without crashing, then quit the app.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/KidReminder/KidReminderApp.swift macos-app/Sources/KidReminder/ContentView.swift macos-app/build.sh
git commit -m "macos-app: wire up 英语试卷 sidebar entry + epaper-runner window group

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 17: `admin.html` — 英语试卷 tab + review dialog + mistake bank

**Files:**
- Modify: `backend/admin.html`

**Interfaces:**
- Consumes: `/api/epaper/*` routes (Tasks 3, 6, 7); reuses the existing `api()` helper
  (admin.html, defined ~line 632) and CSS classes already defined for the science tab
  (`.card`, `.sci-item-card`, `.sci-point-row`, `.sci-failure-row` pattern is generic by
  class name, not science-specific — reused as-is, no new CSS needed).

- [ ] **Step 1: Add the tab buttons**

Right after the existing science tab buttons (admin.html:262-263):

```html
        <button class="tab" id="tabEpaper" hidden>📘 英语试卷批改</button>
        <button class="tab" id="tabEpaperMistakes" hidden>📕 英语试卷错题本</button>
```

- [ ] **Step 2: Add the view containers**

Right after the science view containers (admin.html:392-400):

```html
    <!-- 英语试卷 (all-question English Paper 2) grading queue -->
    <div id="epaperView" hidden>
      <div class="card">
        <div class="vocab-summary" id="epaperSummary"></div>
        <div id="epaperList"></div>
      </div>
    </div>

    <!-- 英语试卷错题本 management (sticky — only cleared here, never automatically) -->
    <div id="epaperMistakesView" hidden>
      <div class="card">
        <div class="vocab-summary">错题本里的题只会在这里手动移出，答对了也不会自动清掉。</div>
        <div id="epaperMistakeList"></div>
      </div>
    </div>
```

- [ ] **Step 3: Add the review dialog**

Right after `</dialog>` closing the `scienceGradeDialog` (admin.html:558):

```html
<dialog id="epaperGradeDialog" class="sci-grade-dialog">
  <h3 id="epaperDlgTitle">📘 批改英语试卷</h3>
  <p>选择题/填空题已经自动判分——如果自动判错了（比如漏收了一个同义答案），点一下切换。问答题按点勾选，关键词初判只做参考。</p>
  <div id="epaperItems"></div>
  <div class="msg err" id="epaperDlgErr"></div>
  <div class="row">
    <button class="ghost" id="epaperDlgCancel">Cancel</button>
    <button class="primary" id="epaperDlgSubmit">保存批改</button>
  </div>
</dialog>
```

- [ ] **Step 4: Wire the tabs into `setTab`**

In `setTab(t)` (admin.html:980), add alongside the existing science lines:

```js
    $("#tabEpaper").classList.toggle("active", t === "epaper");
    $("#tabEpaperMistakes").classList.toggle("active", t === "epaperMistakes");
```
and
```js
    $("#epaperView").hidden = t !== "epaper";
    $("#epaperMistakesView").hidden = t !== "epaperMistakes";
```
and add `"epaper", "epaperMistakes"` to the `noTaskFab` array (admin.html:1002), and:
```js
    else if (t === "epaper") { refreshEpaper(); }
    else if (t === "epaperMistakes") { refreshEpaperMistakes(); }
```

Wire the tab buttons' click handlers and visibility, alongside the existing science ones
(admin.html:1896-1899):
```js
    $("#tabEpaper").onclick = () => setTab("epaper");
    $("#tabEpaper").hidden = role !== "admin";
    $("#tabEpaperMistakes").onclick = () => setTab("epaperMistakes");
    $("#tabEpaperMistakes").hidden = role !== "admin";
```

- [ ] **Step 5: Write the JS logic**

Right after the science JS block ends (admin.html, after the `sciMistakeRow` function and
its closing, ~line 1600):

```js
  // ---- 英语试卷批改：两档题型，家长可以修改任意一档的判定 -----------------
  let epaperDecisions = {}; // itemId -> { finalCorrect: bool } | { points: {markPointId: bool} }

  async function refreshEpaper() {
    try {
      const sessions = await api("/api/epaper/sessions"); // full history, not just pending
      const el = $("#epaperList");
      el.innerHTML = "";
      if (!sessions.sessions.length) {
        $("#epaperSummary").textContent = "";
        el.innerHTML = '<div class="empty">孩子还没有做过英语试卷练习</div>';
        return;
      }
      const pending = sessions.sessions.filter((s) => s.status === "pending_review").length;
      $("#epaperSummary").textContent = `共 ${sessions.sessions.length} 次练习记录` + (pending ? ` · ${pending} 次待批改` : "");
      for (const s of sessions.sessions) el.appendChild(epaperSessionRow(s));
    } catch (e) { showErr(e.message); }
  }

  function epaperSessionRow(s) {
    const row = document.createElement("div");
    row.className = "card sci-session";
    const title = s.mode === "mistakes" ? "📕 错题本复习" : "📘 英语试卷练习";
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_review") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "reviewed") {
      badge = `<div class="badge">✅ ${s.score_earned}/${s.marks_total}</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次练习";
      row.style.opacity = ".6";
    }
    row.innerHTML = `
      <div class="icon">📘</div>
      <div class="info">
        <div class="count">${title}</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      <button class="del" title="删除这条记录">🗑</button>`;
    if (s.status !== "in_progress") row.onclick = () => openEpaperGradeDialog(s.id);
    row.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("删除这条英语试卷练习记录？")) return;
      try { await api(`/api/epaper/sessions/${s.id}`, { method: "DELETE" }); refreshEpaper(); }
      catch (err) { showErr(err.message); }
    };
    return row;
  }

  async function openEpaperGradeDialog(sessionId) {
    try {
      const data = await api(`/api/epaper/sessions/${sessionId}`);
      // Review is available on ANY completed session, not just pending_review —
      // a parent might reopen an already-reviewed, fully-objective session to
      // fix a mis-graded synonym.
      const readOnly = data.session.status === "in_progress";
      epaperDecisions = {};
      for (const it of data.items) {
        if (it.question_type === "oeq") {
          epaperDecisions[it.id] = { points: {} };
          for (const p of it.points) {
            const finalKnown = p.finalHit === 0 || p.finalHit === 1;
            epaperDecisions[it.id].points[p.markPointId] = finalKnown ? !!p.finalHit : !!p.autoHit;
          }
        } else {
          epaperDecisions[it.id] = { finalCorrect: !!it.final_correct };
        }
      }
      $("#epaperDlgTitle").textContent = readOnly ? "📘 英语试卷练习记录（进行中）" : "📘 批改英语试卷";
      const el = $("#epaperItems");
      el.innerHTML = "";
      data.items.forEach((it, idx) => el.appendChild(epaperItemCard(it, idx, readOnly)));
      $("#epaperDlgErr").textContent = "";
      $("#epaperDlgSubmit").hidden = readOnly;
      $("#epaperDlgCancel").textContent = readOnly ? "关闭" : "Cancel";
      $("#epaperGradeDialog").dataset.sessionId = sessionId;
      $("#epaperGradeDialog").showModal();
    } catch (e) { showErr(e.message); }
  }

  const EPAPER_KIND_LABEL = { keyword: "关键词", textual_evidence: "引用原文", inference: "推理", multi_part: "多个要点" };

  function epaperItemCard(it, idx, readOnly) {
    const card = document.createElement("div");
    card.className = "sci-item-card";
    const imgHtml = it.image ? `<img src="/epaper-images/${encodeURIComponent(it.image)}" alt="" />` : "";
    const ctxHtml = it.context ? `<div class="context">${escapeHtml(it.context)}</div>` : "";
    const answerText = (it.answer || "").trim() || "（没有作答）";

    card.innerHTML = `
      <div class="head"><span>第 ${idx + 1} 题 · ${escapeHtml(it.section)}</span><span>${it.marks} 分</span></div>
      ${ctxHtml}
      ${imgHtml}
      <div class="prompt">${escapeHtml(it.prompt)}</div>
      <div class="answer-box">${escapeHtml(answerText)}</div>
      <div class="grade-area"></div>`;

    const area = card.querySelector(".grade-area");
    if (it.question_type === "oeq") {
      for (const p of it.points) {
        const row = document.createElement("label");
        row.className = "sci-point-row";
        const autoClass = p.autoHit ? "auto-yes" : "auto-no";
        row.innerHTML = `
          <input type="checkbox" ${readOnly ? "disabled" : ""} ${epaperDecisions[it.id].points[p.markPointId] ? "checked" : ""} />
          <div>
            <div class="kind ${autoClass}">${EPAPER_KIND_LABEL[p.pointKind] || p.pointKind}</div>
            <div class="desc">${escapeHtml(p.description)}</div>
          </div>`;
        if (!readOnly) {
          row.querySelector("input").onchange = (e) => { epaperDecisions[it.id].points[p.markPointId] = e.target.checked; };
        }
        area.appendChild(row);
      }
    } else {
      const row = document.createElement("label");
      row.className = "sci-point-row";
      row.innerHTML = `
        <input type="checkbox" ${readOnly ? "disabled" : ""} ${epaperDecisions[it.id].finalCorrect ? "checked" : ""} />
        <div>
          <div class="kind">判定：答对了吗？</div>
          <div class="desc">正确答案：${escapeHtml(it.correct_answer || "")}${it.explanation ? " — " + escapeHtml(it.explanation) : ""}</div>
        </div>`;
      if (!readOnly) {
        row.querySelector("input").onchange = (e) => { epaperDecisions[it.id].finalCorrect = e.target.checked; };
      }
      area.appendChild(row);
    }
    return card;
  }

  $("#epaperDlgCancel").onclick = () => $("#epaperGradeDialog").close();
  $("#epaperDlgSubmit").onclick = async () => {
    const sessionId = $("#epaperGradeDialog").dataset.sessionId;
    const items = Object.entries(epaperDecisions).map(([itemId, d]) => {
      if ("points" in d) {
        return { itemId: Number(itemId), points: Object.entries(d.points).map(([markPointId, hit]) => ({ markPointId: Number(markPointId), hit })) };
      }
      return { itemId: Number(itemId), finalCorrect: d.finalCorrect };
    });
    try {
      await api(`/api/epaper/sessions/${sessionId}/review`, { method: "POST", body: JSON.stringify({ items }) });
      $("#epaperGradeDialog").close();
      refreshEpaper();
    } catch (e) { $("#epaperDlgErr").textContent = e.message; }
  };

  // ---- 英语试卷错题本管理（只在这里手动移出，从不自动清空） -----------------
  async function refreshEpaperMistakes() {
    try {
      const data = await api("/api/epaper/questions?mistakeBank=1&limit=200");
      const el = $("#epaperMistakeList");
      el.innerHTML = "";
      if (!data.questions.length) {
        el.innerHTML = '<div class="empty">错题本是空的 🎉</div>';
        return;
      }
      for (const q of data.questions) el.appendChild(epaperMistakeRow(q));
    } catch (e) { showErr(e.message); }
  }

  function epaperMistakeRow(q) {
    const row = document.createElement("div");
    row.className = "card sci-mistake-row";
    row.innerHTML = `
      <div class="main">
        <div class="prompt">${escapeHtml(q.prompt)}</div>
        <div class="meta">${escapeHtml(q.school)} ${q.year || ""} · ${escapeHtml(q.section)} · ${q.marks} 分</div>
      </div>
      <button class="ghost" title="移出错题本">✅ 已掌握</button>`;
    row.querySelector("button").onclick = async () => {
      if (!confirm("确认这道题已经掌握，移出错题本？")) return;
      try {
        await api(`/api/epaper/questions/${q.id}`, { method: "PATCH", body: JSON.stringify({ inMistakeBank: false }) });
        refreshEpaperMistakes();
      } catch (e) { showErr(e.message); }
    };
    return row;
  }
```

- [ ] **Step 6: Verify with a throwaway server + chrome-devtools MCP**

```bash
rm -f /tmp/epaper-ui-test.db
DB_PATH=/tmp/epaper-ui-test.db PORT=2099 node backend/server.js &
sleep 1
```

Then use the chrome-devtools MCP tools (`navigate_page` to `http://127.0.0.1:2099/admin`,
log in as admin with the throwaway server's default PIN, `take_snapshot`) to confirm the
"📘 英语试卷批改" and "📕 英语试卷错题本" tabs render and are clickable without a console
error, then `evaluate_script` to confirm `document.querySelector('#epaperView')` exists.
Kill the throwaway server afterward (`kill %1`).

- [ ] **Step 7: Commit**

```bash
git add backend/admin.html
git commit -m "admin.html: 英语试卷 review dialog covering both grading tiers + mistake bank tab

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 18: Deploy to the Mac Mini + real end-to-end verification

**Files:** none in the repo — this is an operational task against the running production
server (192.168.0.12), following the exact deploy-safety pattern already established for
the science module.

**Interfaces:** none — this is the final integration of everything built in Tasks 1-17.

- [ ] **Step 1: Back up the live server files and DB before touching anything**

```bash
ssh <mac-mini> "cd ~/kidreminder && \
  cp backend/server.js backend/server.js.bak-\$(date +%Y%m%d-%H%M%S) && \
  cp backend/admin.html backend/admin.html.bak-\$(date +%Y%m%d-%H%M%S) && \
  cp backend/kidreminder.db backend/kidreminder.db.bak-\$(date +%Y%m%d-%H%M%S)"
```

- [ ] **Step 2: Snapshot every table's row count before deploying**

```bash
ssh <mac-mini> "sqlite3 ~/kidreminder/backend/kidreminder.db \"
  SELECT 'stamps', COUNT(*) FROM stamps UNION ALL
  SELECT 'tasks', COUNT(*) FROM tasks UNION ALL
  SELECT 'vocab_words', COUNT(*) FROM vocab_words UNION ALL
  SELECT 'english_questions', COUNT(*) FROM english_questions UNION ALL
  SELECT 'science_questions', COUNT(*) FROM science_questions UNION ALL
  SELECT 'science_sessions', COUNT(*) FROM science_sessions;\""
```

Save this output to compare against after deploy.

- [ ] **Step 3: Deploy server.js and admin.html, restart, confirm the new tables migrate cleanly**

```bash
scp backend/server.js <mac-mini>:~/kidreminder/backend/server.js
scp backend/admin.html <mac-mini>:~/kidreminder/backend/admin.html
ssh <mac-mini> "cd ~/kidreminder && node --check backend/server.js && launchctl kickstart -k gui/\$(id -u)/com.kidreminder.server"
sleep 2
ssh <mac-mini> "sqlite3 ~/kidreminder/backend/kidreminder.db '.tables'" | tr -s ' ' '\n' | grep epaper
curl -s http://192.168.0.12:2021/api/health
```

Expected: the five `epaper_*` tables now exist in the live DB; `/api/health` responds `ok`.

- [ ] **Step 4: Deploy the extracted content**

```bash
scp tools/english-papers/aitong-2025-questions.json <mac-mini>:~/kidreminder/tools/english-papers/
scp tools/english-papers/catholichigh-2025-questions.json <mac-mini>:~/kidreminder/tools/english-papers/
scp -r backend/epaper-images/. <mac-mini>:~/kidreminder/backend/epaper-images/
ssh <mac-mini> "cd ~/kidreminder && \
  node tools/english-papers/import.js tools/english-papers/aitong-2025-questions.json && \
  node tools/english-papers/import.js tools/english-papers/catholichigh-2025-questions.json"
curl -s http://192.168.0.12:2021/api/epaper/papers | python3 -m json.tool
```

Expected: both papers listed, 75 questions / 90 marks each.

- [ ] **Step 5: Verify the web admin tabs render on the live server (chrome-devtools MCP)**

Navigate to `http://192.168.0.12:2021/admin`, log in with the real admin PIN, confirm via
`take_snapshot`/`evaluate_script` that "📘 英语试卷批改" and "📕 英语试卷错题本" render, and
that the existing 科学/听写/vocab tabs are all still present and functioning (the
missing-`admin.html` deploy incident from the science rollout — forgetting to scp it
separately from server.js — must not repeat; this step is exactly the check that would
have caught it).

- [ ] **Step 6: Confirm the row-count snapshot from Step 2 is unchanged for every unrelated table**

```bash
ssh <mac-mini> "sqlite3 ~/kidreminder/backend/kidreminder.db \"
  SELECT 'stamps', COUNT(*) FROM stamps UNION ALL
  SELECT 'tasks', COUNT(*) FROM tasks UNION ALL
  SELECT 'vocab_words', COUNT(*) FROM vocab_words UNION ALL
  SELECT 'english_questions', COUNT(*) FROM english_questions UNION ALL
  SELECT 'science_questions', COUNT(*) FROM science_questions UNION ALL
  SELECT 'science_sessions', COUNT(*) FROM science_sessions;\""
```

Compare against Step 2's output — every count must be identical.

- [ ] **Step 7: Build and ship the macOS app update**

```bash
cd macos-app && ./build.sh
```

Distribute per whatever mechanism `AppUpdater` (referenced in `ContentView.swift`) already
uses for the science-module releases (check its update-manifest path before assuming; this
plan does not re-derive that mechanism since it predates this feature).

- [ ] **Step 8: Confirm `audit_log` recorded the deploy-time import mutations under `epaper`**

```bash
ssh <mac-mini> "sqlite3 ~/kidreminder/backend/kidreminder.db \"SELECT path, method FROM audit_log WHERE path LIKE '%epaper%' ORDER BY id DESC LIMIT 5;\""
```

(Note: `import.js` writes directly to SQLite, bypassing the audit log entirely — that's
expected and matches `science-oeq/import.js`'s existing behavior; this step is checking
that any *subsequent* API-driven mutation, e.g. Step 4's curl calls if any hit a mutating
endpoint, or later real usage, gets picked up. If nothing appears yet because only reads
have happened since deploy, that is not a failure — it becomes verifiable the next time
anyone hits a mutating epaper route.)

- [ ] **Step 9: No git commit** (this task is a deploy operation, not a code change —
  everything shippable was already committed in Tasks 1-17)
