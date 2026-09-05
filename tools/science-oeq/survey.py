#!/usr/bin/env python3
"""Survey the downloaded Science prelim PDFs before trying to structure them.

Answers the questions that decide the extraction strategy:
  - Is there a real text layer, or is this a scan that needs OCR?
  - Where does Booklet A (MCQ) end and Booklet B (open-ended) begin?
  - Where does the answer key start? (2025 papers bundle answers in the same PDF.)
  - How many figures are there, and are they vector art or embedded rasters?

That last one matters most. Science diagrams are usually *vector* drawings, so
page.get_images() returns nothing for them and an extract-embedded-images
approach silently loses them. Counting both tells us up front whether figures
have to be captured by rendering a clipped region instead.

Nothing is written unless --dump-pages is passed; this is a read-only report.

Usage:
    python3 survey.py                     # survey ./papers/*.pdf
    python3 survey.py --papers DIR
    python3 survey.py --dump-pages DIR    # also render page PNGs for eyeballing
"""
import argparse
import json
import pathlib
import re
import sys

try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("PyMuPDF not installed. Try: pip3 install pymupdf")

# A page is treated as scanned if it has almost no extractable text.
TEXT_LAYER_MIN_CHARS = 50

# Vector "clusters": raw get_drawings() returns one entry per path, so a single
# diagram can be hundreds of entries. Group them by proximity to get a figure
# count that means something.
CLUSTER_GAP = 24  # points; vertical gap that separates two figures


def classify_page(page):
    text = page.get_text()
    chars = len(text.strip())

    rasters = page.get_image_info()

    # Drawings that are plausibly figure content, not page furniture. Filter out
    # hairline rules and full-width boxes, which are borders/underlines.
    drawings = []
    pw = page.rect.width
    for d in page.get_drawings():
        r = d["rect"]
        if r.width < 8 or r.height < 8:
            continue          # hairline / tick
        if r.width > pw * 0.95 and r.height < 20:
            continue          # full-width rule
        drawings.append(r)

    return text, chars, rasters, drawings


def cluster_rects(rects):
    """Group rects into figures by vertical proximity."""
    if not rects:
        return []
    boxes = sorted(rects, key=lambda r: (r.y0, r.x0))
    clusters = [[boxes[0]]]
    for r in boxes[1:]:
        last = clusters[-1][-1]
        if r.y0 - last.y1 <= CLUSTER_GAP:
            clusters[-1].append(r)
        else:
            clusters.append([r])
    out = []
    for group in clusters:
        u = group[0]
        for r in group[1:]:
            u = u | r
        out.append(u)
    return out


# Section markers. Papers vary in wording, so match generously and report what
# was found rather than assuming a fixed layout.
RE_BOOKLET_A = re.compile(r"booklet\s*a\b", re.I)
RE_BOOKLET_B = re.compile(r"booklet\s*b\b", re.I)
RE_ANSWERS = re.compile(r"\b(answer\s*(key|sheet|scheme)?s?|marking\s*scheme|suggested\s*answers?)\b", re.I)
# "3. ... [2]" — an OEQ stem with its mark allocation in brackets.
RE_MARKS = re.compile(r"\[\s*(\d)\s*\]")


def survey(path, dump_dir=None):
    doc = fitz.open(path)
    pages = []
    first_a = first_b = first_ans = None
    total_chars = 0
    total_marks_brackets = 0

    for i, page in enumerate(doc):
        text, chars, rasters, drawings = classify_page(page)
        total_chars += chars
        figs = cluster_rects(drawings)
        marks = RE_MARKS.findall(text)
        total_marks_brackets += len(marks)

        if first_a is None and RE_BOOKLET_A.search(text):
            first_a = i + 1
        if first_b is None and RE_BOOKLET_B.search(text):
            first_b = i + 1
        # Only treat as the answer section if it looks like a heading-ish hit
        # on a page that isn't just an instruction sheet mentioning "answers".
        if first_ans is None and RE_ANSWERS.search(text) and i > len(doc) * 0.4:
            first_ans = i + 1

        pages.append({
            "page": i + 1,
            "chars": chars,
            "scanned": chars < TEXT_LAYER_MIN_CHARS,
            "rasters": len(rasters),
            "vector_figures": len(figs),
            "mark_brackets": len(marks),
        })

        if dump_dir:
            out = pathlib.Path(dump_dir) / path.stem
            out.mkdir(parents=True, exist_ok=True)
            page.get_pixmap(dpi=110).save(out / f"p{i + 1:03d}.png")

    scanned = sum(1 for p in pages if p["scanned"])
    return {
        "file": path.name,
        "pages": len(doc),
        "avg_chars_per_page": round(total_chars / max(len(doc), 1)),
        "scanned_pages": scanned,
        "is_scan": scanned > len(doc) * 0.5,
        "booklet_a_page": first_a,
        "booklet_b_page": first_b,
        "answers_page": first_ans,
        "total_rasters": sum(p["rasters"] for p in pages),
        "total_vector_figures": sum(p["vector_figures"] for p in pages),
        "mark_brackets": total_marks_brackets,
        "page_detail": pages,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--papers", default="papers", help="directory of PDFs (default: papers)")
    ap.add_argument("--dump-pages", metavar="DIR", help="also render page PNGs here")
    ap.add_argument("--json", metavar="FILE", help="write the full report as JSON")
    args = ap.parse_args()

    pdfs = sorted(pathlib.Path(args.papers).glob("*.pdf"))
    if not pdfs:
        sys.exit(f"no PDFs in {args.papers}/ — run fetch_papers.sh first")

    reports = []
    print(f"{'paper':<22}{'pg':>4}{'chars/pg':>10}{'scan?':>7}{'BkA':>5}{'BkB':>5}"
          f"{'Ans':>5}{'raster':>8}{'vector':>8}{'[m]':>6}")
    print("-" * 80)
    for p in pdfs:
        r = survey(p, args.dump_pages)
        reports.append(r)
        print(f"{r['file']:<22}{r['pages']:>4}{r['avg_chars_per_page']:>10}"
              f"{('YES' if r['is_scan'] else 'no'):>7}"
              f"{(r['booklet_a_page'] or '-'):>5}{(r['booklet_b_page'] or '-'):>5}"
              f"{(r['answers_page'] or '-'):>5}"
              f"{r['total_rasters']:>8}{r['total_vector_figures']:>8}{r['mark_brackets']:>6}")

    print("-" * 80)
    n = len(reports)
    print(f"{n} papers | scans: {sum(1 for r in reports if r['is_scan'])} "
          f"| with Booklet B marker: {sum(1 for r in reports if r['booklet_b_page'])} "
          f"| with answer section found: {sum(1 for r in reports if r['answers_page'])}")
    print(f"figures: {sum(r['total_rasters'] for r in reports)} raster, "
          f"{sum(r['total_vector_figures'] for r in reports)} vector clusters")
    print(f"'[n] marks' brackets seen: {sum(r['mark_brackets'] for r in reports)}")

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(reports, indent=2))
        print(f"\nfull report -> {args.json}")


if __name__ == "__main__":
    main()
