# PSLE Science open-ended question pipeline

Turns P6 Science prelim papers into a bank of open-ended questions with **tagged mark
points**, for the 科学 practice module.

> ⚠️ **This repo is public. Never commit paper content.**
> The PDFs are other schools' copyrighted exam papers, downloaded for one child's personal
> study — fine to use that way, not ours to republish. `.gitignore` excludes `papers/`,
> `survey/`, `survey-report.json`, `*-questions.json` and `backend/science-images/`.
> Commit the tooling, never the content. Same rule the `english-wrong-answers/` pipeline
> already follows.

## Why mark points

PSLE Science OEQ marks are lost on technique, not knowledge — stopping at the observation
without the mechanism, using an everyday word where the scheme wants a scientific one,
ignoring supplied data, missing the controlled-variable mark. Marks are awarded per
distinct scoring point, so a 3-mark question needs three separately-creditable points.

So each question is stored decomposed into its mark points, and each point is **tagged with
its kind** (`observation`, `mechanism`, `keyword`, `data`, `comparison`,
`variable_controlled`, `conclusion`, …). Grading per point means a miss is a *diagnosis*,
not just a lost mark: `GROUP BY point_kind` over a few dozen answers shows which two or
three technique failures the child actually has.

## Scripts

| Script | What it does |
|---|---|
| `fetch_papers.sh` | Downloads the 2025 P6 Science prelims into `papers/`. Sequential with a delay, skips files already present. Ten files fetched once — not a crawler. |
| `survey.py` | Reports per paper: page count, text-layer vs scan, Booklet A/B boundaries, raster and **vector** figure counts. Read-only unless `--dump-pages`. |
| `check_answer_layers.py` | Which papers ship an extractable answer key, and whether it carries structural markers (`1st Marking Point:`, `Claim:/Evidence:/Reason:`, `Any two`, `Do Not Accept`). |
| `count_oeq.py` | How many OEQ and mark-bearing parts are recoverable from each answer key. |
| `crop_questions.py` | Renders each question's page region to PNG in `backend/science-images/`. |
| `validate.py` | Checks an extracted question JSON: marks == mark-point count, known `point_kind`s, unique refs, images present, well-formed keyword groups. |
| `grade.py` | Reference keyword auto-grader + a self-test of the matching rules. |

```bash
bash fetch_papers.sh
python3 survey.py --json survey-report.json
python3 check_answer_layers.py
python3 count_oeq.py
python3 crop_questions.py
python3 validate.py acsj-2025-questions.json
python3 grade.py acsj-2025-questions.json --demo
```

Requires **PyMuPDF** only (`pip3 install pymupdf`). No poppler, tesseract or ghostscript.

## What the 2025 papers actually look like

Surveyed 2026-09-05, all ten 2025 papers:

- **The question booklets are scans.** No usable text layer. Scan quality is good and
  fully legible, so a vision model can read them — but no regex parser can.
- **Some pages carry junk OCR text** (Henry Park p1, SCGS p1: `Tota! Time`, `quesUons`).
  Worse than no text layer, because it looks extractable. Don't trust a text layer on a
  question page without checking it.
- **Answer keys are natively digital in 4 of 10 papers** — ACS(J), Henry Park, SCGS,
  Raffles Girls. Those extract cleanly. The other five have only the Booklet A MCQ answer
  grid as text (~345 chars of question numbers); Nanyang has no text at all.
- **Yield: 49 OEQ (Q29–Q41) across those four papers.**
- **ACS(J)'s key is the richest** — it already writes answers the way we want to store
  them: `1st Marking Point:` / `2nd Marking Point:`, explicit `Claim:/Evidence:/Reason:/Link:`,
  `Any two`, and `Do Not Accept` with reasons (negative examples, directly useful for
  keyword matching).

### Figures

Science OEQ lean on diagrams, and **`page.get_images()` is the wrong tool** — most diagrams
are vector art or part of a page scan, so extracting embedded image objects silently drops
them. Capture figures by rendering a **clipped page region**
(`page.get_pixmap(clip=rect, dpi=200)`) instead: format-agnostic, works identically for
vector drawings, scans, tables and graphs.

Crops land in `backend/science-images/` as `<school>-<year>-q<N>.png`, served by a
sprites-style static handler and referenced by filename from the question row.

The crop covers the **whole question region**, not just the diagram, and deliberately
includes the `[2]` mark allocations — they tell the child how many scoring points to
write. The transcribed prompt text is kept for search and future TTS, but the crop is
what gets displayed: a transcription of a scan can be wrong, the image cannot.

## Extracted 2025 papers — the bank

`<school>-2025-questions.json` (all gitignored) — **10 papers** have been
extracted, each verified to match that paper's own stated Section B total
(a useful check that nothing was dropped or double-counted):

| paper_key | parts | marks | notes |
|---|---:|---:|---|
| `acsj-2025` | 35 | 44 | the pilot (see below) |
| `henry-park-2025` | 32 | 39 | 3 mark allocations not legible — inferred against the 44-mark total |
| `raffles-girls-2025` | 30 | 40 | |
| `scgs-2025` | 33 | 41 | |
| `ai-tong-2025` | 33 | 44 | |
| `ch-2025` | 36 | 44 | Catholic High |
| `mgs-2025` | 33 | 44 | MGS (Paya Lebar) |
| `nan-hua-2025` | 36 | 44 | |
| `nanyang-2025` | 31 | 44 | |
| `tao-nan-2025` | 37 | 44 | Q29–Q41 |

Only the **tooling** lives in git (`crop_questions.py` + per-paper `.crop.json`
page-mapping configs, `validate.py`, `grade.py`, `import.js`). The papers
themselves, the extracted `*-questions.json`, `survey-report.json`, and
`backend/science-images/` are all **gitignored** — see the warning at the top.

### ACS(J) 2025 — the pilot set

`acsj-2025-questions.json` (gitignored): **35 question parts across Q29–Q40, 44 marks** —
which matches the paper's own stated "(44 marks)" exactly.

Mark-point kinds, over those 44 marks:

| kind | n | | kind | n |
|---|--:|---|---|--:|
| mechanism | 17 | | comparison | 2 |
| identification | 9 | | keyword | 2 |
| suggestion | 5 | | data | 2 |
| conclusion | 3 | | aim / observation / variable_controlled / definition | 1 each |

`mechanism` being 39% of all marks is consistent with the research: explaining *why* is
both the largest scoring category and the most common thing children omit.

One part is unusable in a typing app — **34(a) is a circuit to be drawn**, flagged
`answer_mode: "drawing"`. Seven more are `short` (one word or a number).

### Does keyword matching actually work?

`grade.py --demo` runs 16 cases covering each failure mode. All pass:

| answer | verdict |
|---|---|
| "The thick fur traps a layer of air. Air is a poor conductor of heat…" | ✅ 1/1 |
| "The thick fur keeps them warm at night." | ❌ 0/1 — misses `mechanism` (observation only) |
| "The fur traps air which is an **insulator**…" | ✅ 1/1 — different wording, same science |
| "The lid is **transparent**… the cup is **opaque**" | ✅ 1/1 |
| "The lid is see-through but the cup is not see-through" | ❌ 0/1 — misses `keyword` (everyday words) |
| "left hand gained heat… right hand lost heat" | ✅ 1/1 |
| "His left hand gained heat from the hot coffee" | ❌ 0/1 — misses `comparison` (one side only) |
| "increase the mass of duck B" | ❌ 0/1 — on the paper's own *Do Not Accept* list |

That is the core hypothesis working: a miss is not just a lost mark, it names *which
technique failed*.
