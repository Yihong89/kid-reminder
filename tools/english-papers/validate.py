#!/usr/bin/env python3
"""Validate an extracted English Paper 2 question JSON before it reaches the DB.

Two grading tiers share one file, distinguished by question_type:
  mcq / fill_blank  -- needs correct_answer (mcq also needs options including it)
  oeq               -- needs mark_points, and marks == len(mark_points), same
                       invariant as tools/science-oeq/validate.py

Usage:
    python3 validate.py aitong-2025-questions.json [--images DIR]
"""
import argparse
import json
import pathlib
import sys
from collections import Counter

SECTIONS = {
    "grammar_mcq", "vocab_mcq", "cloze_mcq", "comprehension_mcq",
    "cloze_wordbank", "editing", "cloze_open", "synthesis", "comprehension_oeq",
}
TYPES = {"mcq", "fill_blank", "oeq"}
KINDS = {"keyword", "textual_evidence", "inference", "multi_part"}


def check_groups(groups, where, errs):
    if not isinstance(groups, list) or not groups:
        errs.append(f"{where}: keyword groups must be a non-empty list")
        return
    for g in groups:
        if not isinstance(g, list) or not g or not all(isinstance(s, str) and s for s in g):
            errs.append(f"{where}: each group must be a non-empty list of strings, got {g!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--images", default="../../backend/epaper-images")
    args = ap.parse_args()

    data = json.loads(pathlib.Path(args.file).read_text())
    qs = data["questions"]
    imgdir = pathlib.Path(args.images)

    errs, warns = [], []
    refs = Counter()
    section_count = Counter()
    total_marks = 0

    for q in qs:
        ref = q.get("source_ref", "<missing>")
        refs[ref] += 1
        section = q.get("section")
        section_count[section] += 1
        if section not in SECTIONS:
            errs.append(f"{ref}: unknown section {section!r}")

        qtype = q.get("question_type")
        if qtype not in TYPES:
            errs.append(f"{ref}: unknown question_type {qtype!r}")

        marks = q.get("marks")
        if not isinstance(marks, int) or marks < 1:
            errs.append(f"{ref}: marks must be a positive int, got {marks!r}")
            marks = 0
        total_marks += marks

        if not q.get("prompt"):
            errs.append(f"{ref}: prompt is required")

        img = q.get("image")
        if img and not (imgdir / img).exists():
            errs.append(f"{ref}: image not found: {imgdir / img}")

        if qtype in ("mcq", "fill_blank"):
            if not q.get("correct_answer"):
                errs.append(f"{ref}: {qtype} needs correct_answer")
            if qtype == "mcq":
                opts = q.get("options")
                if not isinstance(opts, list) or len(opts) < 2:
                    errs.append(f"{ref}: mcq needs options (list of >= 2 strings)")
                else:
                    alts = [a.strip().lower() for a in q["correct_answer"].split("/")]
                    if not any(o.strip().lower() in alts for o in opts):
                        errs.append(f"{ref}: correct_answer {q['correct_answer']!r} not found in options {opts!r}")
            if q.get("mark_points"):
                errs.append(f"{ref}: {qtype} must not carry mark_points")
        elif qtype == "oeq":
            pts = q.get("mark_points", [])
            if len(pts) != marks:
                errs.append(f"{ref}: marks={marks} but {len(pts)} mark_points")
            for p in pts:
                where = f"{ref}#{p.get('seq')}"
                kind = p.get("point_kind")
                if kind not in KINDS:
                    errs.append(f"{where}: unknown point_kind {kind!r}")
                if not p.get("description"):
                    warns.append(f"{where}: no description — the child sees this after answering")
                if "keywords" not in p:
                    errs.append(f"{where}: needs keywords")
                else:
                    check_groups(p["keywords"], where, errs)

    for ref, n in refs.items():
        if n > 1:
            errs.append(f"duplicate source_ref: {ref} x{n}")

    print(f"{len(qs)} question parts, {total_marks} marks total")
    print("\nsection distribution:")
    for k, n in section_count.most_common():
        print(f"  {k:<22}{n}")

    if warns:
        print(f"\n{len(warns)} warning(s):")
        for w in warns:
            print(f"  ! {w}")
    if errs:
        print(f"\n{len(errs)} ERROR(s):")
        for e in errs:
            print(f"  x {e}")
        sys.exit(1)
    print("\nOK — no errors")


if __name__ == "__main__":
    main()
