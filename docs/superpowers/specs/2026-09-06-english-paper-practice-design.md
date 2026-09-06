# 英语 PSLE 完整试卷练习模块 — design

## Context

Kid is P5, sits PSLE 2027. The 科学(Science) OEQ module (mark-point decomposition +
keyword auto-check + parent review, papers browsed by school/year, mistakes fed into a
sticky mistake bank) already shipped and is in daily use. The user has 14 downloaded 2025
P6 English "Preliminary Examination" PDFs in `tools/english-papers/papers/` and wants an
equivalent module — but covering **every question in the paper**, not just the
open-ended subset, since most of an English Paper 2 is objectively markable.

### What's actually in the 14 PDFs

Each PDF's cover page names only the first component bound into it (often "Paper 1
(Writing)" or "Listening Comprehension"), which is misleading — spot-checks of Ai Tong and
Catholic High confirmed each PDF is actually a **full bundle**: Paper 1 (Writing) + Paper 2
Booklet A + Paper 2 Booklet B + a complete scanned answer key (all ~75 answers, including
worked comprehension answers), stitched together by whatever site they were sourced from.
Pages have no OCR text layer (pure scans) except the occasional cover page, so extraction
is vision-based reading of rendered page images, exactly as was done for the six
harder-to-read Science papers.

Paper 2 (Language Use and Comprehension) has a standard structure, confirmed identical
across the two schools inspected so far:

- **Booklet A — 25 questions / 25 marks, all MCQ**: 10 grammar cloze MCQ, 5 vocabulary MCQ,
  5 vocabulary-in-context MCQ (shared passage), 5 comprehension MCQ (2 short texts, often
  with a poster/ad image).
- **Booklet B — 50 questions / 65 marks, all open-ended**: 10 cloze with a word bank
  (choose a lettered word), 10 editing (fix a spelling/grammar error, one word per blank),
  15 open cloze (no word bank), 5 sentence synthesis/transformation, 10 comprehension
  open-ended questions (1–4 marks each, based on Booklet A's own reading passage).

Decided scope (confirmed with the user): **Paper 2 only** — Paper 1 (composition) and any
Listening Comprehension paper are excluded; composition can't be auto-graded and listening
needs audio, neither fits this module. ~75 gradable items per paper, ~65 of them objective
and ~10 open-ended, across up to 14 papers (~1000+ items total if fully scaled).

## Core design

**Two grading tiers in one schema**, distinguished by `question_type`:

- `mcq` / `fill_blank` (~65/75 items): single correct answer, possibly with accepted
  alternatives (`"answer1 / answer2"`), objectively right or wrong. Auto-graded the instant
  the kid submits — no ambiguity, no need to wait for a parent.
- `oeq` (~10/75 items, the Booklet B comprehension questions): decomposed into mark points
  exactly like 科学 — each point has a `point_kind`, a `description`, and a keyword
  AND-of-ORs matcher. Auto-hit is provisional; a parent confirms.

This is the same mechanism as 科学 for the `oeq` tier, extended with a fast, unambiguous
auto-grade path for the ~87% of items that don't need judgment at all — the kid gets
instant feedback on Booklet A instead of waiting for a parent to open the admin panel.

**Parent review covers both tiers, not just oeq.** Auto-grading can misjudge an accepted
synonym or shorthand answer as wrong; the review dialog lets a parent flip `finalCorrect`
on any objective item, not only score the oeq mark points. Review is also not gated to
a one-time "pending" state — any completed session, including a fully auto-graded one that
never needed review, can be reopened from the session list and re-scored. Saving a review
recomputes the session's score and updates the mistake bank from whatever the final
verdicts say.

**Auto-computed score.** Every session tracks `score_earned` / `marks_total`. Both are set
at `complete` time from whatever is known then (auto-verdicts for everything, since oeq
points are provisional at that point) and recomputed whenever a review is saved.

**Mistake bank is sticky, uniformly across both tiers** (matching the user's explicit
instruction, carried over unchanged from 科学): a question enters `in_mistake_bank` on any
wrong final verdict — objective miss or missed oeq point — and is **never auto-cleared by
a later correct answer**. Only an explicit parent action (`PATCH inMistakeBank:false`)
removes it. This applies to MCQ/fill-blank misses too, even though right/wrong there is
unambiguous — consistency of the rule was an explicit user choice over the "objective
answers can auto-clear" alternative.

## Data model (`backend/server.js` schema block)

New, parallel table set — **not** a reuse of `english_questions`/`english_quiz_sessions`,
which is a different, existing feature (admin-authored wrong-answer flashcards, floored
`correct_count`, no paper grouping). Naming and shape mirror `science_*` closely enough
that admin.html's dialog code can mostly be shared/adapted rather than rewritten.

```sql
CREATE TABLE epaper_questions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  paper_key     TEXT NOT NULL,        -- e.g. 'aitong-2025'
  paper_seq     INTEGER NOT NULL,     -- original question order in the paper
  school        TEXT NOT NULL,
  year          INTEGER,
  section       TEXT NOT NULL,        -- grammar_mcq | vocab_mcq | cloze_mcq |
                                       -- comprehension_mcq | cloze_wordbank |
                                       -- editing | cloze_open | synthesis |
                                       -- comprehension_oeq
  question_type TEXT NOT NULL,        -- 'mcq' | 'fill_blank' | 'oeq'  (grading path)
  context       TEXT NOT NULL DEFAULT '', -- shared passage/cloze text shown above the prompt
  prompt        TEXT NOT NULL,
  options       TEXT,                 -- JSON array, mcq only
  correct_answer TEXT,                -- mcq/fill_blank only; "alt1 / alt2" = either counts
  marks         INTEGER NOT NULL DEFAULT 1,
  image         TEXT NOT NULL DEFAULT '',  -- filename in epaper-images/, posters/ads only
  explanation   TEXT NOT NULL DEFAULT '',
  attempts      INTEGER NOT NULL DEFAULT 0,
  score_total   INTEGER NOT NULL DEFAULT 0,   -- unfloored, same reasoning as science
  in_mistake_bank INTEGER NOT NULL DEFAULT 0, -- sticky; parent-clear only
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE epaper_mark_points (   -- rows only for question_type = 'oeq'
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  question_id INTEGER NOT NULL REFERENCES epaper_questions(id),
  seq         INTEGER NOT NULL,
  point_kind  TEXT NOT NULL,   -- keyword | textual_evidence | inference | multi_part
  description TEXT NOT NULL,
  keywords    TEXT NOT NULL    -- JSON and-of-ors, same matcher as science
);

CREATE TABLE epaper_sessions (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  mode         TEXT NOT NULL,             -- 'paper' | 'mistakes'
  paper_key    TEXT NOT NULL DEFAULT '',
  status       TEXT NOT NULL DEFAULT 'in_progress', -- in_progress -> reviewed (no oeq items)
                                                       -- or -> pending_review -> reviewed
  score_earned INTEGER,
  marks_total  INTEGER,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  completed_at TEXT,
  reviewed_at  TEXT
);

CREATE TABLE epaper_session_items (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id     INTEGER NOT NULL REFERENCES epaper_sessions(id),
  question_id    INTEGER NOT NULL REFERENCES epaper_questions(id),
  seq            INTEGER NOT NULL,
  answer         TEXT,
  auto_correct   INTEGER,   -- mcq/fill_blank, set at submit
  final_correct  INTEGER    -- mcq/fill_blank, defaults to auto_correct; parent can flip
);

CREATE TABLE epaper_item_points (   -- rows only for oeq items
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id       INTEGER NOT NULL REFERENCES epaper_session_items(id),
  mark_point_id INTEGER NOT NULL REFERENCES epaper_mark_points(id),
  auto_hit      INTEGER,
  final_hit     INTEGER
);
```

Add `epaper` to the audit-log path regex alongside `science`.

## Grading and scoring flow

1. **Submit** (`POST /api/epaper/sessions/:id/items/:itemId/submit`, body `{answer}`):
   - `mcq`/`fill_blank`: normalize (reuse the existing `normalizeEnglishAnswer`), compare
     against each `/`-separated alternative in `correct_answer`, set `auto_correct` =
     `final_correct`. Kid sees right/wrong + `explanation` immediately.
   - `oeq`: keyword-match each mark point (reuse the science matcher), set `auto_hit` per
     point. Kid sees "submitted, awaiting review".
2. **Complete** (`POST .../complete`): `marks_total` = sum of all item marks;
   `score_earned` = sum of marks for items whose current verdict (auto, since nothing's
   been reviewed yet) is correct/hit. If the session has zero `oeq` items, status goes
   straight to `reviewed`; otherwise `pending_review`.
3. **Review** (`POST .../review`, admin, open to *any* completed session, not only
   `pending_review` ones): body carries both shapes —
   ```json
   {"items":[
     {"itemId": 1, "finalCorrect": false},
     {"itemId": 2, "points": [{"markPointId": 5, "hit": true}]}
   ]}
   ```
   Server writes `final_correct`/`final_hit`, recomputes `score_earned`, and updates
   `in_mistake_bank` on every touched question from the new final verdicts (set on any
   miss, cleared only via the separate `PATCH inMistakeBank:false`). Status becomes
   `reviewed`, `reviewed_at` stamped.

## API surface (`backend/server.js`)

Mirrors `/api/science/*` route-for-route:

| Path | Auth | Notes |
|---|---|---|
| `GET /api/epaper/papers` | open | school/year/item counts, grouped by `paper_key` |
| `POST /api/epaper/sessions` | open | `{paperKey}` or `{mistakes:true}` |
| `POST /api/epaper/sessions/:id/items/:itemId/submit` | open | body `{answer}` |
| `POST /api/epaper/sessions/:id/complete` | open | → `reviewed` or `pending_review` |
| `GET /api/epaper/sessions` | admin | full session list (not just pending) |
| `GET /api/epaper/sessions/:id` | admin | session detail for the review dialog |
| `POST /api/epaper/sessions/:id/review` | admin | body per above |
| `DELETE /api/epaper/sessions/:id` | admin | test-data cleanup, same as science |
| `PATCH /api/epaper/questions/:id` | admin | `{inMistakeBank:false}` — manual clear only |
| `GET /epaper-images/:file` | open | static, same 3-layer traversal guard as `science-images` |

## Images

Only the Booklet A comprehension-MCQ sections carry images (poster/ad graphics shared by
several sub-questions); everything else is plain text. Same pattern as science:
`epaper-images/` directory populated out-of-band by the import tool, `image` filename
column, static handler reusing the existing traversal defence. No upload UI.

## macOS app

New sidebar entry "英语试卷" next to 科学, opening `EnglishPaperPracticeView`: a papers
list (school + year + item count) plus a 📕错题本 button, both opening a shared
`WindowGroup(id:"epaper-runner", for:)` window — reusing the exact windowing setup already
proven stable for 科学 (`.windowResizability(.contentMinSize)`, not `.defaultSize`, per the
crash history documented in that module).

The runner plays items in `paper_seq` order for a paper, or in randomized order for the
mistake bank (matching 科学's exact rule: mistake mode drops the fixed ordering). Per
`question_type`:

- `mcq`: tappable option buttons; on submit, highlight correct/incorrect immediately.
- `fill_blank`: single-line text field; on submit, show correct/incorrect + `explanation`
  immediately.
- `oeq`: multi-line text field (same bounded `TextEditor` fix used in the science runner —
  no `TextField(axis:.vertical)` in a `ScrollView`, that combination is what caused the
  original AutoLayout crash); on submit, show only "submitted".

No score or history is shown in the kid-facing view — matching the explicit constraint
carried over from 科学 ("不要，只要试卷列表和错题本入口").

## Admin review (`backend/admin.html`)

New "英语试卷" tab: paper/import status list, a session list (not filtered to pending —
any completed session can be opened), and a review dialog adapted from
`scienceGradeDialog`. The dialog renders every item in original order: objective items as
a row with the kid's answer, the auto-verdict, and a toggle to flip it; oeq items as the
existing per-mark-point checkbox block. A mistake-bank tab mirrors `sciMistakeRow`
(manual-clear button, no auto behavior).

## Extraction pipeline & pilot

Same tooling shape as `tools/science-oeq/`: render pages to PNG with PyMuPDF (no text
layer to extract from), read visually, hand-write `<slug>-2025-questions.json`, a
`<slug>.crop.json` for the image regions that need cropping (comprehension-MCQ posters
only), `validate.py` (extended: `marks == len(mark_points)` only applies to `oeq` rows;
`mcq`/`fill_blank` rows need `correct_answer` non-empty and, for `mcq`, `options` present
and including it), then `import.js` (same UPDATE-in-place-on-reimport approach that fixed
the FK bug in science).

**Pilot on 2 papers first, not all 14**: Ai Tong and Catholic High — both already spot-
checked and confirmed to have fully readable bundled answer keys. Build and verify the
complete path (schema → API → import → app → web review) against these two before deciding
whether to extract the remaining 12. Composition pages are skipped entirely when mapping
`paper_seq`; the answer-key pages at the end of each PDF are the source for
`correct_answer`/`explanation`/oeq model answers, cross-validated against the paper's own
booklet mark totals the same way science's importer was validated (44 marks exactly, no
gaps) — here Booklet A (25) + Booklet B (65) = 90 marks per paper is the check target.

## Honest limitations

Same caveats as 科学, plus one specific to this module: keyword-based auto-grading on
`fill_blank`/`synthesis` items is more failure-prone than MCQ, since these accept short
free text with legitimate phrasing variance (e.g. sentence-transformation answers) — this
is exactly why the review dialog can override objective verdicts, not just oeq ones, and
why review is available on every session rather than gated to a first-pass-only flow.

## Verification

- `node --check backend/server.js`; exercise a fresh throwaway DB end-to-end (start
  session → submit mixed mcq/fill_blank/oeq → complete → confirm `pending_review` iff an
  oeq item exists → review flips an objective verdict → confirm `score_earned` and mistake
  bank both update) before touching the live DB.
- Confirm `audit_log` picks up `epaper` mutations after the regex change.
- Deploy: back up `server.js`/`admin.html`/`kidreminder.db` first, scp both files (the
  missing-`admin.html`-deploy incident from the science rollout must not repeat), verify
  the new tab renders via chrome-devtools MCP, snapshot all table row counts before/after,
  clean up any test-generated sessions afterward.
