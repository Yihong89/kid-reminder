#!/usr/bin/env python3
"""Validate an extracted question JSON before it reaches the database.

The whole design rests on "marks = number of scoring points", so a question
whose mark_points don't add up to its marks would teach the child the wrong
thing about how the paper is scored. Cheap to check, expensive to discover
later.

Checks:
  - marks == len(mark_points)                (unless the point uses need_n)
  - point_kind is in the known vocabulary
  - source_ref is unique
  - referenced image files exist
  - keywords / any_of are well-formed (list of groups of strings)
  - a point has exactly one of keywords / any_of
  - total marks per question number, and the paper total

Usage:
    python3 validate.py acsj-2025-questions.json [--images DIR]
"""
import argparse
import json
import pathlib
import sys
from collections import Counter, defaultdict

KINDS = {
    "observation", "mechanism", "keyword", "data", "comparison",
    "variable_independent", "variable_dependent", "variable_controlled",
    "conclusion", "aim", "prediction", "suggestion", "definition",
    "identification",
}
MODES = {"text", "short", "drawing"}


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
    ap.add_argument("--images", default="../../backend/science-images")
    args = ap.parse_args()

    data = json.loads(pathlib.Path(args.file).read_text())
    qs = data["questions"]
    imgdir = pathlib.Path(args.images)

    errs, warns = [], []
    refs = Counter()
    per_q = defaultdict(int)
    total_marks = 0
    kind_count = Counter()
    mode_count = Counter()

    for q in qs:
        ref = q.get("source_ref", "<missing>")
        refs[ref] += 1
        marks = q.get("marks")
        pts = q.get("mark_points", [])

        if not isinstance(marks, int) or marks < 1:
            errs.append(f"{ref}: marks must be a positive int, got {marks!r}")
            marks = 0
        total_marks += marks
        per_q[q.get("question_no")] += marks

        # marks == number of scoring points. A single point carrying need_n
        # (an "any two of..." point) still counts as the one mark it is worth.
        if len(pts) != marks:
            errs.append(f"{ref}: marks={marks} but {len(pts)} mark_points")

        mode = q.get("answer_mode", "text")
        mode_count[mode] += 1
        if mode not in MODES:
            errs.append(f"{ref}: unknown answer_mode {mode!r}")

        img = q.get("image")
        if img and not (imgdir / img).exists():
            errs.append(f"{ref}: image not found: {imgdir / img}")

        for p in pts:
            where = f"{ref}#{p.get('seq')}"
            kind = p.get("point_kind")
            kind_count[kind] += 1
            if kind not in KINDS:
                errs.append(f"{where}: unknown point_kind {kind!r}")
            if not p.get("description"):
                warns.append(f"{where}: no description — the child sees this after answering")

            has_kw, has_any = "keywords" in p, "any_of" in p
            if has_kw == has_any:
                errs.append(f"{where}: needs exactly one of keywords / any_of")
            if has_kw:
                check_groups(p["keywords"], where, errs)
            if has_any:
                alts = p["any_of"]
                if not isinstance(alts, list) or len(alts) < 2:
                    errs.append(f"{where}: any_of needs >= 2 alternatives")
                else:
                    for i, alt in enumerate(alts):
                        check_groups(alt, f"{where}.any_of[{i}]", errs)
                need = p.get("need_n")
                if not isinstance(need, int) or not (1 <= need <= len(alts)):
                    errs.append(f"{where}: need_n must be 1..{len(alts)}, got {need!r}")

        if mode == "drawing":
            warns.append(f"{ref}: answer_mode=drawing — cannot be graded from typed text")

    for ref, n in refs.items():
        if n > 1:
            errs.append(f"duplicate source_ref: {ref} x{n}")

    print(f"{len(qs)} question parts across {len(per_q)} questions, {total_marks} marks total")
    print("\nmarks per question:")
    for qn in sorted(k for k in per_q if k is not None):
        print(f"  Q{qn}: {per_q[qn]}")
    print("\npoint_kind distribution:")
    for k, n in kind_count.most_common():
        print(f"  {k:<22}{n}")
    print("\nanswer_mode:", dict(mode_count))

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
