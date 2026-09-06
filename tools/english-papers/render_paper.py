#!/usr/bin/env python3
"""Render every page of an English prelim PDF to PNG for vision reading.

Outputs to survey/<slug>/pNNN.png (zero-padded), matching the convention the
existing extracted papers used. Also prints a quick inventory of pages with any
OCR text (to help locate the answer key and the reading-stimulus pages).

Usage:
    python3 render_paper.py papers/2025-english-henrypark.pdf henrypark
"""
import sys, pathlib
import fitz

def main():
    pdf = sys.argv[1]
    slug = sys.argv[2]
    outdir = pathlib.Path("survey") / slug
    outdir.mkdir(parents=True, exist_ok=True)
    doc = fitz.open(pdf)
    print(f"{pdf}: {len(doc)} pages -> {outdir}/")
    for i in range(len(doc)):
        p = doc[i]
        pix = p.get_pixmap(dpi=110)  # ~828px wide, matching existing renders
        (outdir / f"p{i+1:03d}.png").write_bytes(pix.tobytes("png"))
        t = p.get_text("text").strip()
        if len(t) > 30:
            print(f"  p{i+1:>2}  textchars={len(t):4}  {t[:50]!r}")
    print("done")

if __name__ == "__main__":
    main()
