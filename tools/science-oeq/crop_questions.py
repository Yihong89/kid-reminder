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

Config-driven so the same script covers every paper: a JSON file maps question
numbers to the 1-based PDF pages they occupy. Falls back to the ACS(J) mapping
baked in below when no --config is given, matching the original single-paper
usage.

Usage:
    python3 crop_questions.py                                  # ACS(J) default
    python3 crop_questions.py --config scgs.crop.json
"""
import argparse
import json
import pathlib
import sys

try:
    import fitz
except ImportError:
    sys.exit("PyMuPDF not installed. Try: pip3 install pymupdf")

# Fallback config — the original ACS(J) mapping, kept so the no-config
# invocation still works exactly as before.
DEFAULT_CONFIG = {
    "paper": "papers/2025-acs-junior.pdf",
    "slug": "acsj-2025",
    "question_pages": {
        "29": [22], "30": [23], "31": [24], "32": [25], "33": [26], "34": [27],
        "35": [28, 29], "36": [30], "37": [31, 32], "38": [33], "39": [34], "40": [35],
    },
}

# Fractions of page width/height. Right edge is deliberately past the text
# column so the "[2]" mark allocations stay in frame — they tell the child how
# many scoring points to write.
CLIP = (0.105, 0.040, 0.925, 0.880)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", help="JSON file with paper/slug/question_pages; "
                                     "defaults to the ACS(J) mapping")
    ap.add_argument("--out", default="../../backend/science-images")
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    cfg = json.loads(pathlib.Path(args.config).read_text()) if args.config else DEFAULT_CONFIG

    doc = fitz.open(cfg["paper"])
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    written = 0
    # Sort numerically even though JSON keys are strings.
    for qno in sorted(cfg["question_pages"], key=int):
        pages = cfg["question_pages"][qno]
        for idx, pno in enumerate(pages):
            page = doc[pno - 1]
            r = page.rect
            clip = fitz.Rect(r.width * CLIP[0], r.height * CLIP[1],
                             r.width * CLIP[2], r.height * CLIP[3])
            # Multi-page questions get -1, -2 so the app can show them in order.
            suffix = "" if len(pages) == 1 else f"-{idx + 1}"
            name = f"{cfg['slug']}-q{qno}{suffix}.png"
            page.get_pixmap(clip=clip, dpi=args.dpi).save(out / name)
            print(f"  q{qno}{suffix:<2} page {pno:>2} -> {name}")
            written += 1

    print(f"\n{written} images -> {out}/")


if __name__ == "__main__":
    main()
