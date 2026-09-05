#!/usr/bin/env python3
"""Count the open-ended questions recoverable from each paper's answer key.

Only counts papers whose answer section is native text (see
check_answer_layers.py). Booklet A is 28-30 MCQs, so Booklet B question
numbers start around 29 — anything numbered >= 29 with a sub-part label is an
OEQ part worth a mark point.

Usage:
    python3 count_oeq.py [--papers DIR] [--min-q 29]
"""
import argparse
import pathlib
import re
import sys

try:
    import fitz
except ImportError:
    sys.exit("PyMuPDF not installed. Try: pip3 install pymupdf")

TEXT_PAGE_MIN_CHARS = 300

# Matches the answer key's part labels in the several styles seen across
# papers: "35b", "39bii", "Q30) a)i)", "29 (a)", "b Thick forest is cooler".
RE_PART = re.compile(
    r"(?:^|\n)\s*(?:Q\s*)?(\d{1,2})\s*\)?\s*[\(\s]*([a-d])?\s*\)?\s*(i{1,3})?\b",
    re.M,
)


def parts_for(doc, min_q):
    texty = [i for i, p in enumerate(doc) if len(p.get_text().strip()) > TEXT_PAGE_MIN_CHARS]
    blob = "\n".join(doc[i].get_text() for i in texty)
    seen = set()
    for qn, letter, roman in RE_PART.findall(blob):
        n = int(qn)
        if n < min_q or n > 60:
            continue
        seen.add((n, letter or "", roman or ""))
    questions = {q for q, _, _ in seen}
    return questions, seen


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--papers", default="papers")
    ap.add_argument("--min-q", type=int, default=29,
                    help="first Booklet B question number (default 29)")
    args = ap.parse_args()

    pdfs = sorted(pathlib.Path(args.papers).glob("*.pdf"))
    tq = tp = 0
    print(f"{'paper':<24}{'OEQ':>6}{'parts':>7}   range")
    print("-" * 60)
    for p in pdfs:
        doc = fitz.open(p)
        qs, parts = parts_for(doc, args.min_q)
        if not qs:
            print(f"{p.name:<24}{'-':>6}{'-':>7}   (no answer text layer)")
            continue
        tq += len(qs)
        tp += len(parts)
        print(f"{p.name:<24}{len(qs):>6}{len(parts):>7}   Q{min(qs)}–Q{max(qs)}")
    print("-" * 60)
    print(f"{'TOTAL':<24}{tq:>6}{tp:>7}   mark-bearing parts recoverable as text")


if __name__ == "__main__":
    main()
