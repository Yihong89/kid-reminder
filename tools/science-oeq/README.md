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

```bash
bash fetch_papers.sh
python3 survey.py --json survey-report.json
python3 check_answer_layers.py
python3 count_oeq.py
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
