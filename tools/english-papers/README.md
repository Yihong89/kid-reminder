# PSLE English Paper 2 pipeline

Turns a P6 English "Preliminary Examination" PDF (Paper 2: Language Use and
Comprehension) into a bank of auto- and mark-point-graded questions for the
英语试卷 practice module. Design background:
`docs/superpowers/specs/2026-09-06-english-paper-practice-design.md`.

> ⚠️ **This repo is public. Never commit paper content.**
> The PDFs are other schools' copyrighted exam papers, downloaded for one child's
> personal study — fine to use that way, not ours to republish. `.gitignore` excludes
> `papers/`, `survey/`, `*-questions.json` and `backend/epaper-images/`.
> Commit the tooling (`*.py`, `*.js`, `*.sh`, `*.crop.json`), never the content.

## What the paper looks like

Each PDF is typically a full bundle: Paper 1 (Writing) + Paper 2 Booklet A + Paper 2
Booklet B + a scanned answer key, stitched together regardless of what the cover page
claims. **Pages are scans with no usable text layer** — extraction is vision-based
reading of rendered page images, not OCR/regex.

Paper 2 structure (confirmed identical across every 2025 paper processed so far):

- **Booklet A — 25 MCQ / 25 marks**: 10 grammar cloze, 5 vocabulary, 5
  vocabulary-in-context (shared passage), 5 comprehension (2 short texts, usually with a
  poster/ad image for Text 1).
- **Booklet B — 50 items / 65 marks, all open-ended on the answer sheet but only ~10 are
  actually free-form grading**: 10 cloze with a word bank, 10 editing (one misspelled/
  wrong-form word per blank), 15 open cloze (no word bank), 5 sentence synthesis/
  transformation, 10 comprehension open-ended (based on Booklet A's own reading passage,
  1–4 marks each).
- **90 marks total.** Use this as the cross-check after transcription — if your
  `marks` sum doesn't add up to 90, something was mis-scoped or double-counted.

Only Paper 2 is in scope. Paper 1 (composition) and any Listening Comprehension
component are skipped entirely — neither can be auto-graded, and listening needs audio.

## Pipeline

### 1. Add the PDF

Drop it in `papers/` as `2025-english-<slug>.pdf` (bump the year when it's a 2026
paper — the rest of this doc says `2025` because that's what's live today).

### 2. Render pages for vision reading

```bash
python3 render_paper.py papers/2026-english-<slug>.pdf <slug>
```

Writes `survey/<slug>/p001.png`, `p002.png`, … and prints which pages carry any
extractable text (almost always none — a scanned cover page at most).

⚠️ **Don't assume these renders are all the same DPI.** `render_paper.py` defaults to
110dpi, but older renders in this repo measured ~100dpi. If you ever need to convert a
pixel position on a `survey/` PNG back to PDF point-space (as `crop_passage.py` does),
compute the *actual* dpi per page from `pixmap.width * 72 / page.rect.width` — don't
trust a hardcoded constant.

### 3. Transcribe into `<slug>-2026-questions.json`

Read every Booklet A + Booklet B page (`survey/<slug>/pNNN.png`) and the answer-key
pages at the end, and hand-write the questions JSON. Top level:

```json
{"_source": "<School> P6 Prelim 2026", "_note": "optional", "questions": [ ... ]}
```

Each element of `questions` is one gradable part, in the paper's own order (this order
becomes `paper_seq` on import — it's what "做完整张卷子" replays). Field reference:

| Field | Required | Notes |
|---|---|---|
| `source_ref` | always | Unique, e.g. `"<slug>-2026-q1"`. Duplicates are a validate.py error. |
| `section` | always | One of the 9 values below. |
| `question_type` | always | `mcq` \| `fill_blank` \| `oeq` — picks the grading path. |
| `prompt` | always | The question text the kid sees. |
| `marks` | always | Positive int. `oeq` rows must have exactly this many `mark_points`. |
| `context` | optional | Shared cloze/editing passage shown above the prompt, or (for `comprehension_mcq`) the "Text 1 is a poster for X, Text 2 is an extract from Y" framing line. |
| `passage` | comprehension only | The full reading passage, duplicated identically across every item in that comprehension group. |
| `options` | `mcq` only | Array of ≥2 strings, must include `correct_answer`. |
| `correct_answer` | `mcq`/`fill_blank` | `"alt1 / alt2"` — either counts as correct. |
| `explanation` | `mcq`/`fill_blank` | Shown to the kid right after grading. |
| `image` | comprehension only | Filename in `backend/epaper-images/` — see step 5. |
| `mark_points` | `oeq` only | See below. |

`section` values: `grammar_mcq`, `vocab_mcq`, `cloze_mcq`, `comprehension_mcq`,
`cloze_wordbank`, `editing`, `cloze_open`, `synthesis`, `comprehension_oeq`.

**`mark_points`** (oeq only) is a list of `{seq, point_kind, description, keywords}`:
`point_kind` ∈ `keyword | textual_evidence | inference | multi_part`; `keywords` is a
list of AND-of-OR groups — `[["disgusted"]]` means that one group must match;
`[["shocked","surprised"],["angry","upset"]]` means one word from *each* group must
appear. `description` is shown to the kid after grading, so write it as feedback
("Disgusted"), not as an internal note.

Worked examples from a real paper, one per distinct *shape* (`editing`/`cloze_open`/
`vocab_mcq`/`cloze_mcq` aren't shown separately — they're the same shape as
`cloze_wordbank`/`grammar_mcq` below, just a different `section` value):

<details><summary>mcq (grammar_mcq)</summary>

```json
{
  "source_ref": "mgs-2025-q1", "section": "grammar_mcq", "question_type": "mcq",
  "prompt": "The sudden loud noise woke the baby and made her ________.",
  "options": ["cry", "cries", "cried", "crying"], "correct_answer": "cry", "marks": 1,
  "explanation": "\"make\" + bare infinitive (causative) — the noise made the baby 'cry'."
}
```
</details>

<details><summary>fill_blank, shared cloze passage (cloze_wordbank)</summary>

```json
{
  "source_ref": "mgs-2025-q26", "section": "cloze_wordbank", "question_type": "fill_blank",
  "context": "Word bank: (A) as (B) at ... Reading ___(26)___ been important for thousands of years...",
  "prompt": "Choose the letter for blank (26) from the word bank.",
  "correct_answer": "F", "marks": 1, "explanation": "has (F) \"Reading has been important...\"."
}
```
</details>

<details><summary>comprehension_mcq (Text 1 poster + Text 2 extract, shared by Q21-25)</summary>

```json
{
  "source_ref": "mgs-2025-q21", "section": "comprehension_mcq", "question_type": "mcq",
  "prompt": "\"...connect ... under the stars\". The image in the poster in Text 1 supports this by depicting people ________.",
  "options": ["picnicking in one place", "relaxing in a cosy room", "sitting under the open sky", "coming together for a feast"],
  "correct_answer": "sitting under the open sky", "marks": 1,
  "context": "Text 1 is a poster for a \"Film Show at the Park\" community event, and Text 2 is an extract from a talk given at a Community Club.",
  "image": "mgs-2025-q21.png",
  "passage": "A strong community makes us feel safe and connected..."
}
```
`image` here is the Text 1 poster crop (step 5a); `passage` is Text 2's extract, shown
as plain text (no line numbers needed — comprehension_mcq questions never cite lines).
</details>

<details><summary>oeq (comprehension_oeq, one mark point)</summary>

```json
{
  "source_ref": "mgs-2025-q66", "section": "comprehension_oeq", "question_type": "oeq",
  "context": "Every Sunday, Rui En stood at her parents' wet market stall...",
  "prompt": "In the first paragraph... What did Rui En think her classmates would feel? [1m] She thought they would be ________.",
  "marks": 1,
  "mark_points": [{"seq": 1, "point_kind": "keyword", "description": "Disgusted", "keywords": [["disgusted"]]}],
  "passage": "Every Sunday, Rui En stood at her parents' wet market stall...",
  "image": "mgs-2025-passage.png"
}
```
`image` is the passage-with-line-numbers crop from step 5b — set this on **every**
`comprehension_oeq` item in the group, not just the first.
</details>

<details><summary>fill_blank, sentence transformation (synthesis)</summary>

```json
{
  "source_ref": "mgs-2025-q61", "section": "synthesis", "question_type": "fill_blank",
  "context": "He did not throw the ball in time. The team missed the chance to score.",
  "prompt": "Had ________.",
  "correct_answer": "he thrown the ball in time, the team would not have missed the chance to score",
  "marks": 2,
  "explanation": "Inversion with 'Had' (third conditional) to express the unrealised past condition."
}
```
</details>

### 4. Cross-check before validating

- Sum of `marks` across the whole file should be **90** (Booklet A 25 + Booklet B 65).
  If not, recount before moving on — a wrong total almost always means a
  missed/duplicated question, not a legitimately different paper.
- If the bundle's scanned answer key is legible, use it for `correct_answer` /
  `explanation` / oeq model answers, not just your own read of the question — the
  school's own marking scheme is the authority on accepted synonyms.

### 5. Crop the images

Comprehension passages constantly cite specific printed lines (`"...(line 20)"`), and
the poster in `comprehension_mcq` is genuinely a picture, not describable text — both
need a cropped PNG in `backend/epaper-images/`, not just transcribed text.

**5a. Text 1 poster** (`comprehension_mcq`, `<slug>-2025-q21.png`): no dedicated script
yet. Find the page in `survey/<slug>/`, then crop it directly with PyMuPDF, e.g.:

```python
import fitz
doc = fitz.open("papers/2026-english-<slug>.pdf")
page = doc[<page_index>]                      # 0-indexed
pix = page.get_pixmap(dpi=240, clip=fitz.Rect(x0, y0, x1, y1))  # points, not survey pixels
pix.save("../../backend/epaper-images/<slug>-2025-q21.png")
```
Record the page number in `<slug>.crop.json` (`{"paper": ..., "slug": ..., "question_pages": {"21": [<page_index+1>]}}`)
for future reference.

**5b. Comprehension passage with line numbers** (`comprehension_oeq`,
`<slug>-2025-passage.png`): use `crop_passage.py`, which auto-detects the passage's
printed border box and crops it at high DPI straight from the PDF.

1. Find which `survey/<slug>/pNNN.png` the passage starts on — either read pages near
   Booklet A's end by eye, or OCR-search for the first few words of the passage
   (`brew install tesseract && pip3 install pytesseract pillow`, then loop
   `pytesseract.image_to_string()` over the survey pages).
2. Add `"<slug>": <page_no>` to `PAGES` in `crop_passage.py`. If the passage runs onto
   a second printed page (check: does the highest `(line N)` cited by any question
   exceed what's visible on that one page? does the crop end mid-sentence with no
   `Adapted from ...` citation?), also add `"<slug>": <page_no+1>` to `CONT_PAGES` —
   the script stitches both pages into one image automatically.
3. Run it and eyeball the result:
   ```bash
   python3 crop_passage.py <slug>
   ```
   Confirm: every printed line number is visible and legible, nothing is cut off at
   the right edge (some papers print line numbers *outside* the border, not inside),
   and — if two pages were stitched — the join reads as one continuous passage with no
   duplicated or missing line.
4. Set `"image": "<slug>-2025-passage.png"` on every `comprehension_oeq` item (all 10
   share one passage, so one filename covers the whole group).

If the auto-detected box is visibly wrong (cuts off text, or `crop_passage.py` prints
`NO BOX`), add a manual override to `MANUAL_BOX` in that script rather than fighting
the detector — see the existing `scgs` entry for the pattern.

### 6. Validate

```bash
python3 validate.py <slug>-2025-questions.json
```

Checks: known `section`/`question_type`, `marks == len(mark_points)` for oeq rows,
`mcq` has ≥2 options including `correct_answer`, referenced `image` files actually
exist in `backend/epaper-images/`, no duplicate `source_ref`. Fix every error before
importing — it refuses to import if anything mismatches how the paper is actually
scored.

### 7. Import

```bash
./process_epaper.sh <slug>
```

Validates, copies the JSON + poster image to the Mac Mini, and does a **dry-run**
import there so you can review the `SKIP`/insert counts before anything real happens.
If that looks right:

```bash
ssh robot@192.168.0.12 "cd /Users/robot/kidreminder && /Users/robot/nodejs/bin/node epaper-import.js <slug>-2025-questions.json"
```

If you're only re-importing after fixing the `passage`/`image` field on an
already-imported paper, use `./import_passage.sh <slug>` instead — same validate +
copy + import, plus a check that `passage` actually landed in the DB row.

> ⚠️ **Never run `import.js` on the Mac Mini for an English paper.** That name is
> reused there for the *Science*-OEQ importer (`science_questions` table) — a
> same-named leftover from a different pipeline, not a version mismatch. It doesn't
> error cleanly: it silently skips every non-oeq row ("SKIP marks=1 but 0 mark
> points") and writes the oeq rows into `science_questions` under English source_refs,
> which looks like nothing happened until you count rows. The correct script on the
> Mac Mini is **`epaper-import.js`** (byte-identical to this repo's `import.js` — the
> generic name only collides on the Mac Mini's flat deploy layout, not here). Confirmed
> byte-for-byte with `diff` before trusting either. `process_epaper.sh` /
> `import_passage.sh` already call the right one — that's why they exist, use them
> instead of typing the ssh command by hand.

Before any manual write to the live DB regardless: `cp kidreminder.db
kidreminder.db.bak-<label>-$(date +%Y%m%d-%H%M%S)` on the Mac Mini first, and snapshot
`SELECT COUNT(*), SUM(marks) FROM epaper_questions` before/after so a mistake is
caught by a number that doesn't match, not discovered later.

### 8. Verify

- `GET /api/epaper/papers` should list the new `paper_key` with `questionCount: 75,
  marksTotal: 90`.
- Start a session for it in the macOS app; open the comprehension_oeq step and toggle
  文字/原文行号 — the scan should show every line the questions cite.

## Scripts

| Script | What it does |
|---|---|
| `render_paper.py` | Renders every PDF page to `survey/<slug>/pNNN.png` for vision reading. |
| `validate.py` | Checks an extracted questions JSON against the schema above. |
| `crop_passage.py` | Auto-crops the comprehension_oeq passage (with line numbers) from the PDF; stitches a two-page passage into one image. |
| `import.js` | Direct-SQLite importer — UPDATE-in-place on `source_ref`, preserves attempts/score/mistake-bank on re-import. **On the Mac Mini this same file is deployed as `epaper-import.js`** (see the warning above). |
| `process_epaper.sh <slug>` | validate → copy JSON + poster to Mac Mini → dry-run import there. First-time import of a new paper. |
| `import_passage.sh <slug>` | validate → copy → real import → confirms `passage` landed. Re-import after fixing passage/image data. |
