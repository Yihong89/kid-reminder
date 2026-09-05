#!/usr/bin/env python3
"""Keyword auto-grader for OEQ answers — reference implementation.

This mirrors what the server will do, and exists mainly so the matching rules
can be tested against realistic answers before any of it is built. The verdict
is PROVISIONAL: it is a time-saver on the parent's review, never a replacement
for it.

Matching rules
--------------
Normalise (lowercase, collapse whitespace, strip punctuation) — same treatment
as normalizeEnglishAnswer in backend/server.js — then substring-match.

  keywords: [[a, b], [c]]   ->  (a OR b) AND c
  any_of + need_n           ->  at least need_n of the alternatives match

Substring matching is deliberate: storing the stem "evaporat" matches
evaporate / evaporates / evaporation without needing a stemmer.

Usage:
    python3 grade.py --demo acsj-2025-questions.json     # run the built-in cases
    python3 grade.py FILE --ref acsj-2025-q31b --answer "..."
"""
import argparse
import json
import pathlib
import re
import sys

PUNCT = re.compile(r"[.,!?;:\"'()\[\]]")
WS = re.compile(r"\s+")


def normalize(s):
    return WS.sub(" ", PUNCT.sub(" ", str(s or "").lower())).strip()


def group_hit(text, group):
    """A group is satisfied when ANY of its terms appears."""
    return any(normalize(term) in text for term in group)


def point_hit(text, point):
    """Returns (hit, detail) — detail lists which groups/alternatives matched."""
    if "any_of" in point:
        need = point.get("need_n", 1)
        matched = [i for i, alt in enumerate(point["any_of"])
                   if all(group_hit(text, g) for g in alt)]
        return len(matched) >= need, {"matched_alternatives": matched, "need": need}
    groups = point.get("keywords", [])
    hits = [group_hit(text, g) for g in groups]
    missing = [groups[i] for i, h in enumerate(hits) if not h]
    return all(hits), {"missing_groups": missing}


def grade(question, answer):
    text = normalize(answer)
    results = []
    for p in question.get("mark_points", []):
        hit, detail = point_hit(text, p)
        results.append({
            "seq": p.get("seq"),
            "point_kind": p.get("point_kind"),
            "hit": hit,
            "description": p.get("description", ""),
            "detail": detail,
        })
    score = sum(1 for r in results if r["hit"])
    return {
        "source_ref": question.get("source_ref"),
        "marks": question.get("marks"),
        "auto_score": score,
        "missed_kinds": [r["point_kind"] for r in results if not r["hit"]],
        "points": results,
    }


# Realistic answers, including the failure modes the research says cost the most
# marks. Each case declares the score it should get, so this doubles as a test.
#
# These answers are invented — plausible things a P5/P6 child would write, not
# text copied from the paper or its mark scheme. That keeps this file safe to
# commit under the "tooling yes, paper content no" rule in the README; only the
# source_ref identifiers point at the (gitignored) question set.
DEMO = [
    ("acsj-2025-q31b", "The thick fur traps a layer of air. Air is a poor conductor of heat so less heat is lost from its body.", 1, "full answer"),
    ("acsj-2025-q31b", "The thick fur keeps them warm at night.", 0, "OBSERVATION ONLY — no mechanism"),
    ("acsj-2025-q31b", "The fur traps air which is an insulator so it does not lose heat.", 1, "same science, different wording ('insulator')"),

    ("acsj-2025-q33b", "The plastic lid is transparent so light can pass through, but the paper cup is opaque.", 1, "correct scientific terms"),
    ("acsj-2025-q33b", "The lid is see-through but the paper cup is not see-through.", 0, "EVERYDAY WORDS — should miss"),

    ("acsj-2025-q33a", "His left hand gained heat from the hot coffee and his right hand lost heat to the iced coffee.", 1, "both directions"),
    ("acsj-2025-q33a", "His left hand gained heat from the hot coffee so it felt warm.", 0, "ONE SIDE ONLY — comparison incomplete"),

    ("acsj-2025-q35b", "The amount of water used at the start and the temperature of the surrounding.", 1, "two valid controlled variables"),
    ("acsj-2025-q35b", "The amount of water used at the start.", 0, "only one variable, needs two"),

    ("acsj-2025-q40c", "Shorter. Spreading his hands increases the surface area of the water so it evaporates faster.", 1, "prediction + mechanism"),
    ("acsj-2025-q40c", "Shorter, because the wind can reach more of his hands.", 0, "prediction without the surface-area concept"),

    ("acsj-2025-q38b", "More passengers means the mass of the train increases. This causes greater friction between the wheels and the tracks, so there is more wear and tear.", 2, "both marks"),
    ("acsj-2025-q38b", "The train becomes heavier so it breaks down more often.", 0, "no mechanism at all"),

    ("acsj-2025-q37b", "He can add more batteries to the circuit.", 1, "any_of alternative 1"),
    ("acsj-2025-q37b", "He can increase the number of coils of wire around the iron bar.", 1, "any_of alternative 2"),
    ("acsj-2025-q37b", "He can increase the mass of duck B.", 0, "explicitly on the Do Not Accept list"),
]


def run_demo(qs):
    by_ref = {q["source_ref"]: q for q in qs}
    passed = failed = 0
    for ref, answer, expect, label in DEMO:
        q = by_ref.get(ref)
        if not q:
            print(f"  ?? {ref} not in file")
            continue
        r = grade(q, answer)
        ok = r["auto_score"] == expect
        passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
        flag = "ok " if ok else "FAIL"
        print(f"  {flag} {ref:<22} {r['auto_score']}/{r['marks']} (want {expect})  {label}")
        if not ok or r["missed_kinds"]:
            print(f"        answer: {answer[:78]}")
            if r["missed_kinds"]:
                print(f"        missed: {', '.join(r['missed_kinds'])}")
    print(f"\n{passed} passed, {failed} failed")
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--ref")
    ap.add_argument("--answer")
    args = ap.parse_args()

    qs = json.loads(pathlib.Path(args.file).read_text())["questions"]

    if args.demo:
        sys.exit(1 if run_demo(qs) else 0)

    if not (args.ref and args.answer):
        sys.exit("need --demo, or both --ref and --answer")
    q = next((x for x in qs if x["source_ref"] == args.ref), None)
    if not q:
        sys.exit(f"no such source_ref: {args.ref}")
    print(json.dumps(grade(q, args.answer), indent=2))


if __name__ == "__main__":
    main()
