#!/usr/bin/env python3
"""Crop each Booklet B question out of a scanned paper as a PNG.

Why crop the page rather than extract the figures: these papers are scans, so
there are no separate figure objects to pull out — page.get_images() returns
the whole scanned page. Rendering a clipped region is format-agnostic and works
the same for scans, vector diagrams, tables and graphs.

Why the whole question region rather than just the diagram: the transcribed
prompt text is a transcription and can be wrong, whereas the crop is exactly
what the child would see on paper. The transcription is kept for search and
future TTS; the crop is what gets displayed.

The clip box strips the "Please do not write in the margin" side bars, the page
number and the school footer, keeping the question body and its mark brackets.

Usage:
    python3 crop_questions.py                    # writes ../../backend/science-images/
    python3 crop_questions.py --out DIR --dpi 150
"""
import argparse
import pathlib
import sys

try:
    import fitz
except ImportError:
    sys.exit("PyMuPDF not installed. Try: pip3 install pymupdf")

PAPER = "papers/2025-acs-junior.pdf"
SLUG = "acsj-2025"

# question number -> 1-based PDF pages it occupies
QUESTION_PAGES = {
    29: [22], 30: [23], 31: [24], 32: [25], 33: [26], 34: [27],
    35: [28, 29], 36: [30], 37: [31, 32], 38: [33], 39: [34], 40: [35],
}

# Fractions of page width/height. Right edge is deliberately past the text
# column so the "[2]" mark allocations stay in frame — they tell the child how
# many scoring points to write.
CLIP = (0.105, 0.040, 0.925, 0.880)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper", default=PAPER)
    ap.add_argument("--slug", default=SLUG)
    ap.add_argument("--out", default="../../backend/science-images")
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    doc = fitz.open(args.paper)
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    written = 0
    for qno, pages in sorted(QUESTION_PAGES.items()):
        for idx, pno in enumerate(pages):
            page = doc[pno - 1]
            r = page.rect
            clip = fitz.Rect(r.width * CLIP[0], r.height * CLIP[1],
                             r.width * CLIP[2], r.height * CLIP[3])
            # Multi-page questions get -1, -2 so the app can show them in order.
            suffix = "" if len(pages) == 1 else f"-{idx + 1}"
            name = f"{args.slug}-q{qno}{suffix}.png"
            page.get_pixmap(clip=clip, dpi=args.dpi).save(out / name)
            print(f"  q{qno}{suffix:<2} page {pno:>2} -> {name}")
            written += 1

    print(f"\n{written} images -> {out}/")


if __name__ == "__main__":
    main()
