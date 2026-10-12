#!/usr/bin/env python3
"""Crop each paper's comprehension_mcq Text 1 stimulus (a poster / web page /
advertisement) out of the scanned PDF, for the macOS app to show alongside
Q21-25.

Paper 2 Booklet A always spends one page on the two comprehension_mcq texts:
Text 1 is the pictorial stimulus, Text 2 the written extract. Only Text 1 needs
an image -- Text 2 is transcribed into the question's `passage` field. The
README used to say "no dedicated script yet" and to crop these by hand with a
throwaway snippet; this is that snippet, kept so the page numbers are recorded.

Cropping the whole printed page (at 240 dpi) rather than guessing a box: the
stimulus fills most of its page, and a wrong box silently cuts off the poster
artwork the questions refer to.

Usage:
    python3 crop_poster.py                  # all papers in POSTER_PAGES
    python3 crop_poster.py acsj-p5 mgs       # just these
"""
import sys
from pathlib import Path

import fitz

BASE = Path(__file__).parent
OUT = BASE.parent.parent / "backend" / "epaper-images"
DPI = 240

# slug -> 1-indexed survey page holding the comprehension_mcq Text 1 stimulus.
# Verified by OCR-ing that page for the "Text 1" / "Study the ... texts" line.
POSTER_PAGES = {
    "acsj-p5": 6, "redswastika-p5": 6, "catholichigh-p5": 7,
}


def paper_pdf(slug):
    hits = sorted((BASE / "papers").glob(f"*-english-{slug}.pdf"))
    if not hits:
        return None, None
    return hits[0], hits[0].name.split("-", 1)[0]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ok, fail = [], []
    for slug in (sys.argv[1:] or list(POSTER_PAGES)):
        if slug not in POSTER_PAGES:
            print(f"{slug}: not in POSTER_PAGES")
            fail.append(slug)
            continue
        pdf, year = paper_pdf(slug)
        if pdf is None:
            print(f"{slug}: NO PDF in papers/")
            fail.append(slug)
            continue
        doc = fitz.open(pdf)
        page_no = POSTER_PAGES[slug]
        page = doc[page_no - 1]
        pix = page.get_pixmap(dpi=DPI)
        out = OUT / f"{slug}-{year}-q21.png"
        pix.save(out)
        print(f"{slug}: {pdf.name} p{page_no} -> {out} ({pix.width}x{pix.height})")
        ok.append(slug)
    print(f"\n{len(ok)} ok, {len(fail)} failed: {fail}")


if __name__ == "__main__":
    main()
