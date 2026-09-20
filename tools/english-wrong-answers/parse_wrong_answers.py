#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""Parses wrong-answers.md (from the kid's private mistake-log repo) into
structured quiz question records for import.js. See README.md for where to
get wrong-answers.md and how the two scripts fit together.

Usage: python3 parse_wrong_answers.py /path/to/wrong-answers.md
       (writes parsed-questions.json / unparsed-questions.json next to this script)

Since 2026-09-19 it also *validates* every parsed record and writes the ones the
kid's app cannot present to rejected-questions.json / rejected-questions.md
instead of letting them through — see the "Validation" section below.
r"""
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
    rejected = []
    for b in blocks:
        block_text = "\n".join(b["lines"])
        rec = parse_block(b["number"], b["topic"], b["section_type"], block_text)
        if not rec:
            unparsed.append({"number": b["number"], "topic": b["topic"], "preview": block_text[:200]})
            continue
        tidy(rec)
        reasons = validate_record(rec)
        if reasons:
            rec["reject_reasons"] = [{"code": c, "message": m} for c, m in reasons]
            rec["source_block"] = block_text
            rejected.append(rec)
        else:
            records.append(rec)

    print(f"Total numbered blocks found: {len(blocks)}")
    print(f"Parsed successfully: {len(records)}")
    print(f"Unparsed: {len(unparsed)}")
    print(f"Rejected (not importable in the app): {len(rejected)}")
    by_type = {}
    for r in records:
        by_type[r["type"]] = by_type.get(r["type"], 0) + 1
    print("By type:", by_type)
    if rejected:
        by_code = {}
        for r in rejected:
            for x in r["reject_reasons"]:
                by_code[x["code"]] = by_code.get(x["code"], 0) + 1
        print("Rejection reasons:")
        for code, n in sorted(by_code.items(), key=lambda kv: -kv[1]):
            print(f"  {REJECT_LABELS.get(code, code)}: {n}")

    with open(os.path.join(OUT_DIR, "parsed-questions.json"), "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
    with open(os.path.join(OUT_DIR, "unparsed-questions.json"), "w", encoding="utf-8") as f:
        json.dump(unparsed, f, ensure_ascii=False, indent=2)
    write_rejected(rejected)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# The kid's app shows ONLY `prompt` (+ `options` for mcq). There is nowhere to
# attach a passage, a flyer or an image, and no per-question instruction beyond
# what the prompt itself says. So a record that references material outside the
# prompt, or that asks the child to transform a sentence without saying into
# what, is unusable — the child just sees a dead end.
#
# This is not hypothetical: on 2026-09-19, 74 of the 240 imported rows were
# exactly like that (61 transformation questions with no instruction, 12
# comprehension questions whose options and source text were never captured,
# 1 with corrupted markdown). They were found by the child, not by the importer.
# Rejecting them here means import.js never puts them in front of the child.
#
# Rejected records keep their full original block text in rejected-questions.json
# (+ a readable rejected-questions.md) so a parent can re-enter them once the
# missing material is found.

BLANK_MARKER_RE = re.compile(r"\*\*\\_+\*\*|\*\*\([^)]*\)\*\*|\\_\\_|_{2,}")
INSTRUCTION_RE = re.compile(
    r"rewrite|combine|begin(?:ning)?\s+with|using\s+[\"'\u201c]|"
    r"in the passive voice|in the active voice|in reported speech|in direct speech|"
    r"change\b.{0,30}\binto|turn\b.{0,30}\binto|replace\b.{0,30}\bwith|"
    r"join the two|make\b.{0,30}\binto",
    re.I)
TARGET_STEM_RE = re.compile(r"(?:->|\u2192)\s*\S")
COMPREHENSION_RE = re.compile(
    r"which of the following|what is the main|what does the word\b|refer to|"
    r"the main purpose|main idea|best describes|according to the|"
    r"which key learning|which statement|is a fact\b|most suitable",
    re.I)
OPTION_LETTER_ANSWER_RE = re.compile(r"^[\(\[]?\s*[A-D1-4]\s*[\)\]]?$")
_N = r"(?:this|that|the)"
MISSING_TEXT_RE = re.compile(
    r"\bTexts?\s*[12]\b|"
    + _N + r"\s+(?:flyer|poster|advertisement|notice|passage|image|extract|"
    r"article|sign|brochure|diagram|chart|table|noticeboard)\b",
    re.I)

REJECT_LABELS = {
    "missing_prompt": "题干为空",
    "missing_answer": "答案为空",
    "unbalanced_markdown": "题干 ** 标注损坏（不配对）",
    "bad_options": "选项有问题",
    "answer_not_in_options": "正确答案不在选项里",
    "comprehension_without_options": "理解/词汇选择题却没有选项",
    "references_missing_text": "引用了题库里存不下的外部材料（Text 1/flyer 等）",
    "transformation_without_instruction": "改写题没有改写指令",
}


def _is_option_letter_answer(ans):
    """答案形如 'B' / '(4)' / '[3]' —— 说明这题原本是选择题。"""
    return bool(OPTION_LETTER_ANSWER_RE.match(ans.strip())) or bool(re.match(r"^\(\d\)", ans.strip()))


def tidy(rec):
    """入库前的纯美化清理（不改语义，跑在校验之前）。"""
    # 有些非选择题的答案前面粘了一个多余的列表号 "N. "
    rec["correct_answer"] = re.sub(r"^\d+\.\s*", "", rec.get("correct_answer") or "").strip()
    # 有些选择题的题干尾部粘了选项行自己的空位标记，例如
    #   'What does **"deter"** mean? — **\_'
    # 留着会让 ** 不配平、并在 App 里露出星号。题目本身是完整的，清掉即可。
    rec["prompt"] = re.sub(
        r"\s*[\u2014\u2013-]\s*\*\*\\_+\s*\.?\s*$", "", (rec.get("prompt") or "").strip()
    ).strip()


def validate_record(rec):
    """Returns a list of (code, 中文说明). Empty list = safe to import."""
    reasons = []
    prompt = (rec.get("prompt") or "").strip()
    answer = (rec.get("correct_answer") or "").strip()
    options = rec.get("options")

    if not prompt:
        reasons.append(("missing_prompt", REJECT_LABELS["missing_prompt"]))
    if not answer:
        reasons.append(("missing_answer", REJECT_LABELS["missing_answer"]))

    # --- mcq: options must be usable, and the answer must be one of them -----
    # 选择题的题干即使 markdown 有点脏（多几个 ** 之类）也还做得出来——选项才是题目本身，
    # 所以这里不查 markdown；但要查「有没有引用 App 显示不了的材料」。
    if options is not None:
        if MISSING_TEXT_RE.search(prompt):
            reasons.append(("references_missing_text", REJECT_LABELS["references_missing_text"]))
        if not isinstance(options, list) or len(options) != 4:
            n = len(options) if isinstance(options, list) else 0
            reasons.append(("bad_options", f"选项不是 4 个（实际 {n} 个）"))
        else:
            norm = [str(o).strip().lower() for o in options]
            if any(not o for o in norm):
                reasons.append(("bad_options", "有空选项"))
            elif len(set(norm)) != len(norm):
                reasons.append(("bad_options", "选项有重复"))
            alts = [a.strip().lower() for a in answer.split("/") if a.strip()]
            if alts and not any(a in norm for a in alts):
                reasons.append(("answer_not_in_options", REJECT_LABELS["answer_not_in_options"]))
        return reasons

    # --- no options: either a genuine fill-in, or something unanswerable -----
    # 没有选项时，题干就是全部内容，markdown 坏了就等于题坏了（例如 'understand → **analyse'）。
    if prompt.count("**") % 2:
        reasons.append(("unbalanced_markdown", REJECT_LABELS["unbalanced_markdown"]))
    if COMPREHENSION_RE.search(prompt) or _is_option_letter_answer(answer):
        reasons.append(("comprehension_without_options", REJECT_LABELS["comprehension_without_options"]))
    if MISSING_TEXT_RE.search(prompt):
        reasons.append(("references_missing_text", REJECT_LABELS["references_missing_text"]))
    if reasons:
        return reasons

    # A blank marker means the child knows where to type — nothing more needed.
    if BLANK_MARKER_RE.search(prompt):
        return reasons
    # Otherwise this must be a transformation, and it must say what to do:
    # either an instruction word ("Rewrite ... using ...") or a target stem ("-> Each of ...").
    if INSTRUCTION_RE.search(prompt) or TARGET_STEM_RE.search(prompt):
        return reasons
    reasons.append(("transformation_without_instruction", REJECT_LABELS["transformation_without_instruction"]))
    return reasons


def write_rejected(rejected):
    r"""Dumps rejected records so a parent can find and re-enter them later."""
    json_path = os.path.join(OUT_DIR, "rejected-questions.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(rejected, f, ensure_ascii=False, indent=2)

    md = ["# 被拦下的英语错题", "",
          "这些题在 `parse_wrong_answers.py` 的校验里没通过，**没有**进入 `parsed-questions.json`，",
          "所以也不会被 `import.js` 写进孩子的错题练习。", "",
          "原因基本都是：**App 只能显示题干（和选择题的选项），存不下原文、图片或额外指引**，",
          "所以引用了 Text 1 / flyer / 段落的题、以及没写清楚要改成什么的改写题，孩子看到就是死路。", "",
          "找到原始试卷后，可以照着下面每条的「原始片段」重新录入。", "",
          f"共 **{len(rejected)}** 条。", "", "---", ""]
    for r in rejected:
        md.append(f"## #{r.get('number')} · {r.get('topic') or '(无主题)'}")
        md.append("")
        md.append(f"- **问题类型**：{r.get('type')}")
        for x in r.get("reject_reasons", []):
            md.append(f"- **拦下原因**：{x['message']}（`{x['code']}`）")
        md.append(f"- **题干**：{r.get('prompt')}")
        md.append(f"- **答案**：{r.get('correct_answer')}")
        if r.get("options"):
            md.append(f"- **选项**：{json.dumps(r['options'], ensure_ascii=False)}")
        block = (r.get("source_block") or "").strip()
        if block:
            md.append("")
            md.append("<details><summary>原始片段（用于重新录入）</summary>")
            md.append("")
            md.append("```")
            md.append(block)
            md.append("```")
            md.append("</details>")
        md.append("")
    with open(os.path.join(OUT_DIR, "rejected-questions.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md))
    print(f"Wrote {len(rejected)} rejected records to rejected-questions.json / rejected-questions.md")



def clean(s):
    s = s.strip()
    s = re.sub(r"^\*+|\*+$", "", s).strip()
    s = re.sub(r"^✅\s*", "", s).strip()
    return s

LABEL_SPLIT_RE = re.compile(r"\(([1-4])\)|([A-D])[.)]|([1-4])[.)]\s*")
VALID_LABEL_SETS = ({"A", "B", "C", "D"}, {"1", "2", "3", "4"})

def options_from_text(s):
    """Pull labelled options out of one line. Returns ({label: value}, [label, ...]).

    The source uses two label styles — "A. ..." and "(1) ..." — sometimes on one
    line separated by &emsp;, sometimes one option per line.
    """
    parts = LABEL_SPLIT_RE.split(s)
    out, order = {}, []
    for i in range(1, len(parts), 4):
        label = parts[i] or parts[i + 1] or parts[i + 2]
        val = parts[i + 3] if i + 3 < len(parts) else ""
        if not label or label in out:
            continue
        v = re.sub(r"&emsp;", " ", val)
        # 选项行里夹着标记：&emsp; 分隔，**✅ 标出正确项，** 是加粗。
        # 旧的正则靠 [^&*✅] 顺手排掉，换成分行/分组解析后必须显式清掉。
        v = v.replace("**", "").replace("✅", "").replace("❌", "")
        out[label] = re.sub(r"\s+", " ", v).strip()
        order.append(label)
    return out, order


def find_options(block_text):
    """Returns (options_raw, labels, before_text, after_text) or None.

    Handles both layouts that appear in the source:
      * all four options on ONE line  — "A. x B. y C. z D. w" / "(1) x (2) y ..."
      * ONE option per line           — "A. x\nB. y\nC. z\nD. w"
    The old single-line-only, A.-dot-only regex silently missed the second layout
    and the "(1)" style, which is why some comprehension questions reached the
    app with no options at all (2026-09-19).
    """
    lines = block_text.split("\n")
    for i, line in enumerate(lines):
        opts, order = options_from_text(line)
        if len(opts) == 4 and set(order) in VALID_LABEL_SETS:
            return ([opts[l] for l in order], order,
                    "\n".join(lines[:i]), "\n".join(lines[i + 1:]))
    for i in range(len(lines)):
        acc, order, j = {}, [], i
        while j < len(lines) and len(acc) < 4:
            if not lines[j].strip():
                j += 1
                continue
            o, od = options_from_text(lines[j])
            if len(o) != 1 or od[0] in acc:
                break
            acc[od[0]] = o[od[0]]
            order.append(od[0])
            j += 1
        if len(acc) == 4 and set(order) in VALID_LABEL_SETS:
            return ([acc[l] for l in order], order,
                    "\n".join(lines[:i]), "\n".join(lines[j:]))
    return None

def extract_prompt(before_text):
    r"""题干 = 原句 +（如果有）紧跟着的目标句式脚手架行。

    原文里 S&T 题是这样写的::

        31. Father and my brothers are not going for the fishing trip tomorrow.
            **Neither** **\_** **nor** **\_** .
            → **Answer:** Neither father nor my brothers ...

    第二行就是给孩子的改写起点（PSLE S&T 的正式卷面格式）。以前只取第一行，
    把脚手架丢了，孩子就只看到一句原句、不知道该改成什么 —— 2026-09-19 修的。
    """
    lines = before_text.split("\n")
    out = [lines[0]] if lines and lines[0].strip() else []
    for l in lines[1:4]:
        t = l.strip()
        if not t:
            continue
        # 只在「明显是脚手架」时才收：含空位标记 **\_，且不是解释/答案行
        if "\\_" in t and not t.startswith((">", "→", "->", "❌", "📌")):
            out.append(t)
            continue
        break
    return clean(" ".join(out))


def parse_block(number, topic, section_type, block_text):
    # --- try MCQ: find the line listing "A. ... B. ... C. ... D. ..." (any noise/✅/** allowed between) ---
    found = find_options(block_text)
    if found:
        options_raw, labels, before_opts, after_opts = found
        if True:
            options_by_letter = {lbl: clean(val) for lbl, val in zip(labels, options_raw)}
            label_pattern = "[A-D]" if labels[0] in "ABCD" else "[1-4]"
            correct = None
            # style A: "**Correct: D. word**" / "**Correct: word**" on a later line
            cm = re.search(r"\*\*Correct:\s*(" + label_pattern + r"\.?\s*)?(.+?)\*\*", after_opts)
            if cm:
                correct = clean(cm.group(2))
                letter = cm.group(1)
                if letter and letter.strip(". ") in options_by_letter:
                    correct = options_by_letter[letter.strip(". ")]
            # "**Correct: B**" 会让上面的 group(1) 回溯成空、group(2) 抓到裸字母，
            # 于是 correct 停在 "B" 而没有还原成选项文字。这里补一次 label→文字 的解析。
            if correct and correct.strip("()[] .").upper() in options_by_letter:
                correct = options_by_letter[correct.strip("()[] .").upper()]
            if correct is None:
                # style B: inline "✅ D." (or "D. ... ✅") within the options line itself
                em = re.search(r"✅\s*(" + label_pattern + r")\.|(" + label_pattern + r")\.[^&\n]*✅", block_text)
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
        prompt = extract_prompt(block_text[: am.start()])
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
        prompt = extract_prompt(block_text[: pm.start()])
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
        prompt = extract_prompt(block_text[: cm.start()])
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
