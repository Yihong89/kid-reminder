#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parses wrong-answers.md (from the kid's private mistake-log repo) into
structured quiz question records for import.js. See README.md for where to
get wrong-answers.md and how the two scripts fit together.

Usage: python3 parse_wrong_answers.py /path/to/wrong-answers.md
       (writes parsed-questions.json / unparsed-questions.json next to this script)
"""
import re
import sys
import json
import os

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "wrong-answers.md")
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
STOP_HEADER = "## Summary of Topics"  # everything from here on is reference material, not question items

def classify_section(header_text):
    h = header_text.lower()
    if "multiple choice" in h or "mastery quiz" in h:
        return "mcq"  # some "mastery quiz" sections are MCQ; per-block MCQ detection will override if wrong
    if "sentence transformation" in h or h.strip() == "s&t mastery quiz 1" or "reported speech" in h:
        return "sentence_transform"
    return "fill_blank"

def main():
    text = open(SRC, encoding="utf-8").read()
    stop_idx = text.find(STOP_HEADER)
    if stop_idx != -1:
        text = text[:stop_idx]
    lines = text.split("\n")

    # walk lines, tracking current header context and collecting question blocks
    header_stack = {"h1": "", "h2": "", "h3": ""}
    numbered_start_re = re.compile(r"^\*{0,2}(\d+)\.\s+(.*)$")
    blocks = []  # (number, section_type, topic, [lines])
    current = None
    last_number = 0  # question numbers only ever increase through the doc; nested "1. 2. 3." explanation
                      # sub-bullets (e.g. inside a "multiple errors:" breakdown) reset low and must be
                      # rejected as new blocks, not treated as new questions

    for line in lines:
        h_match = re.match(r"^(#{1,4})\s+(.*)$", line)
        if h_match:
            level = len(h_match.group(1))
            htext = h_match.group(2).strip()
            if level == 1: header_stack = {"h1": htext, "h2": "", "h3": ""}
            elif level == 2: header_stack["h2"] = htext; header_stack["h3"] = ""
            elif level == 3: header_stack["h3"] = htext
            continue
        m = numbered_start_re.match(line.strip())
        if m and int(m.group(1)) > last_number:
            if current:
                blocks.append(current)
            last_number = int(m.group(1))
            topic = header_stack["h3"] or header_stack["h2"]
            section_type = classify_section(header_stack["h3"] or header_stack["h2"])
            current = {"number": last_number, "topic": topic, "section_type": section_type, "lines": [m.group(2)]}
        elif current is not None:
            current["lines"].append(line)
    if current:
        blocks.append(current)

    records = []
    unparsed = []
    for b in blocks:
        block_text = "\n".join(b["lines"])
        rec = parse_block(b["number"], b["topic"], b["section_type"], block_text)
        if rec:
            records.append(rec)
        else:
            unparsed.append({"number": b["number"], "topic": b["topic"], "preview": block_text[:200]})

    # cosmetic cleanup: strip a stray leading "N. " list-marker some non-MCQ answers retained
    # (e.g. an accepted-answers list where only the first item got captured)
    for r in records:
        r["correct_answer"] = re.sub(r"^\d+\.\s*", "", r["correct_answer"]).strip()

    print(f"Total numbered blocks found: {len(blocks)}")
    print(f"Parsed successfully: {len(records)}")
    print(f"Unparsed: {len(unparsed)}")
    by_type = {}
    for r in records:
        by_type[r["type"]] = by_type.get(r["type"], 0) + 1
    print("By type:", by_type)

    with open(os.path.join(OUT_DIR, "parsed-questions.json"), "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
    with open(os.path.join(OUT_DIR, "unparsed-questions.json"), "w", encoding="utf-8") as f:
        json.dump(unparsed, f, ensure_ascii=False, indent=2)


OPTS_LINE_RE = re.compile(r"(?:A\..*B\..*C\..*D\.)|(?:1\..*2\..*3\..*4\.)")
OPTION_RE = re.compile(r"([A-D]|[1-4])\.\s*([^&*✅\n]+?)\s*(?:&emsp;|\*\*|✅|$)")

def clean(s):
    s = s.strip()
    s = re.sub(r"^\*+|\*+$", "", s).strip()
    s = re.sub(r"^✅\s*", "", s).strip()
    return s

def find_options_line(block_text):
    for line in block_text.split("\n"):
        if OPTS_LINE_RE.search(line):
            return line
    return None

def parse_block(number, topic, section_type, block_text):
    # --- try MCQ: find the line listing "A. ... B. ... C. ... D. ..." (any noise/✅/** allowed between) ---
    opts_line = find_options_line(block_text)
    if opts_line:
        found = OPTION_RE.findall(opts_line)
        labels = [lbl for lbl, _ in found]
        options_by_letter = {lbl: clean(val) for lbl, val in found}
        if len(options_by_letter) == 4:
            options_raw = [options_by_letter[l] for l in labels]  # preserve source order (A-D or 1-4)
            label_pattern = "[A-D]" if labels[0] in "ABCD" else "[1-4]"
            idx = block_text.find(opts_line)
            before_opts = block_text[:idx]
            after_opts = block_text[idx + len(opts_line):]
            correct = None
            # style A: "**Correct: D. word**" / "**Correct: word**" on a later line
            cm = re.search(r"\*\*Correct:\s*(" + label_pattern + r"\.?\s*)?(.+?)\*\*", after_opts)
            if cm:
                correct = clean(cm.group(2))
                letter = cm.group(1)
                if letter and letter.strip(". ") in options_by_letter:
                    correct = options_by_letter[letter.strip(". ")]
            if correct is None:
                # style B: inline "✅ D." (or "D. ... ✅") within the options line itself
                em = re.search(r"✅\s*(" + label_pattern + r")\.|(" + label_pattern + r")\.[^&\n]*✅", opts_line)
                if em:
                    letter = em.group(1) or em.group(2)
                    correct = options_by_letter.get(letter)
            if correct is not None:
                prompt = clean(before_opts.strip().split("\n")[-1] if before_opts.strip() else before_opts)
                # prompt is usually the whole text before the options line
                prompt = clean(" ".join(l for l in before_opts.split("\n") if l.strip()))
                explanation = extract_explanation(after_opts)
                return {
                    "number": number, "type": "mcq", "topic": topic,
                    "prompt": prompt, "options": options_raw, "correct_answer": correct,
                    "explanation": explanation,
                }

    # --- try "→ **Answer:**" / "→ **Correct:**" style (early fill-in-blank batches) ---
    am = re.search(r"→\s*\*\*(?:Answer|Correct):?\*\*:?\s*(.+)", block_text)
    if am:
        correct = clean(am.group(1).split("\n")[0])
        prompt = clean(block_text[: am.start()].split("\n")[0])
        explanation = extract_explanation(block_text[am.end():])
        rtype = "sentence_transform" if section_type == "sentence_transform" else "fill_blank"
        return {
            "number": number, "type": rtype, "topic": topic,
            "prompt": prompt, "options": None, "correct_answer": correct,
            "explanation": explanation,
        }

    # --- try "**Correct:** X" style: bold closes right after the label, answer is plain text after ---
    pm = re.search(r"\*\*Correct(?:\s+answers?)?:\*\*\s*(.+)", block_text)
    if pm:
        correct = clean(pm.group(1).split("\n")[0])
        prompt = clean(block_text[: pm.start()].split("\n")[0])
        explanation = extract_explanation(block_text[pm.end():])
        rtype = "sentence_transform" if section_type == "sentence_transform" else "fill_blank"
        return {
            "number": number, "type": rtype, "topic": topic,
            "prompt": prompt, "options": None, "correct_answer": correct,
            "explanation": explanation,
        }

    # --- try "**Correct: X**" style without MCQ options (fill-blank/spelling/transform) ---
    cm = re.search(r"\*\*Correct:\s*(.+?)\*\*", block_text)
    if cm:
        correct = clean(cm.group(1))
        prompt = clean(block_text[: cm.start()].split("\n")[0])
        explanation = extract_explanation(block_text[cm.end():])
        rtype = "sentence_transform" if section_type == "sentence_transform" else "fill_blank"
        return {
            "number": number, "type": rtype, "topic": topic,
            "prompt": prompt, "options": None, "correct_answer": correct,
            "explanation": explanation,
        }

    return None


def extract_explanation(tail_text):
    parts = []
    for line in tail_text.split("\n"):
        s = line.strip()
        if not s or s == "---":
            continue
        s = re.sub(r"^>\s*", "", s)
        parts.append(s)
        if len(parts) >= 6:
            break
    return "\n".join(parts).strip()


if __name__ == "__main__":
    main()
