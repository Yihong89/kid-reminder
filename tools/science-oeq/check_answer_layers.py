#!/usr/bin/env python3
"""Check which papers ship a real text layer for their answer key.

The 2025 papers are scans of the question booklet, but at least some have the
suggested-answers section appended as native text rather than as scanned
images. That section is what mark points are built from, so whether it is
extractable text or another scan decides how much vision-model work Phase B
needs. This also probes for the structural markers the ACS(J) key uses
("1st Marking Point:", "Claim:/Evidence:/Reason:/Link:", "Any two",
"Do Not Accept"), since those map almost directly onto our mark-point model.

Usage:
    python3 check_answer_layers.py [--papers DIR]
"""
import argparse
import pathlib
import re
import sys

try:
    import fitz
except ImportError:
    sys.exit("PyMuPDF not installed. Try: pip3 install pymupdf")

# A page carrying real answer prose, not just a watermark or page number.
TEXT_PAGE_MIN_CHARS = 300

MARKERS = [
    ("MarkPoint", re.compile(r"marking\s*point", re.I)),
    ("CER", re.compile(r"\bclaim\s*:", re.I)),
    ("AnyN", re.compile(r"any\s+(one|two|three)\b", re.I)),
    ("DoNotAccept", re.compile(r"do\s*not\s*accept", re.I)),
    ("Accept", re.compile(r"\baccept\b", re.I)),
]

# "35b", "39bii", "7a" — the answer key's question labels.
RE_QLABEL = re.compile(r"^\s*(\d{1,2})\s*([a-d](?:i{1,3})?)?\s*$", re.M)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--papers", default="papers")
    args = ap.parse_args()

    pdfs = sorted(pathlib.Path(args.papers).glob("*.pdf"))
    if not pdfs:
        sys.exit(f"no PDFs in {args.papers}/")

    hdr = f"{'paper':<24}{'pg':>4}{'txtpg':>7}{'start':>7}{'chars':>8}{'labels':>8}  markers"
    print(hdr)
    print("-" * len(hdr))

    usable = 0
    for p in pdfs:
        doc = fitz.open(p)
        texty = [i for i, pg in enumerate(doc)
                 if len(pg.get_text().strip()) > TEXT_PAGE_MIN_CHARS]
        start = texty[0] + 1 if texty else None
        blob = "\n".join(doc[i].get_text() for i in texty)
        found = [name for name, rx in MARKERS if rx.search(blob)]
        if "DoNotAccept" in found and "Accept" in found:
            found.remove("Accept")
        labels = len(RE_QLABEL.findall(blob))
        if texty:
            usable += 1
        print(f"{p.name:<24}{len(doc):>4}{len(texty):>7}{str(start or '-'):>7}"
              f"{len(blob):>8}{labels:>8}  {', '.join(found) or '(none)'}")

    print("-" * len(hdr))
    print(f"{usable}/{len(pdfs)} papers have an extractable answer-key text layer")


if __name__ == "__main__":
    main()
