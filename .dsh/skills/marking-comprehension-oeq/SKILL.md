---
name: marking-comprehension-oeq
description: >-
  Mark Singapore primary English Paper 2 comprehension open-ended (OEQ, the 10-question / 20-mark section) the way a school teacher does, not the way a keyword matcher does. Use when marking, reviewing, re-grading or calibrating a comprehension section; when a teacher's marked script needs to be reconciled with the app's score; when deciding whether a pupil's answer deserves full, half or zero marks; when an answer copies from the passage ("lifting"), is too long or off point ("simplify"), or uses the wrong tense. Triggers on — 改卷, 批改, 阅读理解, comprehension open-ended, OEQ, mark points, lifting from text, out of point, simplify, epaper session review, teacher's marking differs.
---

# Marking comprehension open-ended (OEQ) like a teacher

The app's own grader is a keyword matcher with an AI second opinion. It is **too
generous** — measured against a real teacher's script it awarded 15/20 where the
teacher gave 8/20. This skill is how to close that gap.

Read this before touching any OEQ score.

## The standard

Four rules. The first three come from the teacher's own written comments on a
marked script; the fourth is ordinary content marking.

| # | Rule | Effect | Teacher's words |
|---|------|--------|-----------------|
| 1 | **Lifting** — the answer copies chunks of the passage | **Question scores 0** | "Lifting too much from text — out of point" |
| 2 | **Off point / too long** — content that answers nothing | **Lose half the question's marks** | "Simplify instead of lifting wholesale" / "Simplify" |
| 3 | **Grammar or tense disagreeing with the question** | **Lose 1 mark** | corrected `have`→`had`, `understand`→`understood` |
| 4 | **Content** — each mark point must actually be earned | one mark per point | ✗ on the wrong part |

### Rule 1 is conditional, and getting this wrong is the main hazard

Lifting is NOT banned outright. It is penalised when:

- the question expects the pupil's own words, OR
- the copied run drags in material that answers nothing.

It is **correct** when the question asks the pupil to extract:

| Question wording | Lifting is… |
|---|---|
| "pick out a five-word phrase…" | required |
| "what evidence shows…" | expected |
| "quote…", "which phrase…" | required |
| "why did…", "how did…", "explain…" | penalised |

Always read the prompt before charging rule 1. `epaperLiftExpected()` in
`backend/server.js` encodes this and the app labels such questions
"本题要求从文中摘录，属正常".

### What each rule looks like in practice

Rulang 2025, session 53 — a real script the teacher marked:

| Q | Pupil wrote | Our score | Teacher | Why |
|---|---|---|---|---|
| 67 | *"Gita stood nearby, pretending to use her phone though the signal was weak. Hopefully, no one from school would recognise her. Just being there made her cheeks burn. She felt embarrassed to be helping out at the wet market."* | 2/2 | **0/2** | Rule 1 — 89% copied; two of four sentences answer nothing |
| 72 | *"They have a really good relationship and they understand each another very well as Ramani did not even need to ask what happened…"* | 1.5/2 | **0/2** | Rule 2 (33 words for a 2-mark answer) + Rule 3 (present tense in a past-tense passage) |
| 75 | *"When Gita walked past the group of girls who usually made her nervous. She did not lower her eyes… This shows that she felt proud of herself."* | 1.5/2 | **1/2** | Rule 2 — "Simplify instead of lifting wholesale" |
| 69 | *"a) a fishmonger gutting a pomfret with a swift moment / b) the post made by Eileen"* | 2/2 | **1/2** | Rule 4 — (b) wants the *person* (Eileen), not the post |
| 66 | *"She kept her head low"* | 0/1 | 0/1 | Rule 4 — extraction question, but the wrong phrase |
| 73 | *"untidy"* | 1/1 | 1/1 | correct |
| 74 | — | 0/2 | 0/2 | Rule 4 — "meaning incorrect" |

Note what the teacher did **not** do: on Q69, Q70 and Q75 he ignored small
spelling and word-choice slips. He only deducted for lifting, padding and wrong
content. Do not invent extra deductions — an earlier "0.5 per language error"
rule pushed three questions *below* the teacher's marks and had to be removed.

## The detectors

Two of the three rules are measurable. `backend/server.js` exposes them on every
OEQ item in `GET /api/epaper/sessions/:id`.

### `liftRatio` — Rule 1

Sliding a 5-word window over the answer, what fraction of windows appear
verbatim in the passage. `null` when the answer is under 5 words.

- **≥ 0.60** and `liftExpected === false` → charge Rule 1, score 0.
- Suppressed entirely when `liftExpected === true`.

### `offPoint` — Rule 2

The answer is split into sentences and sub-parts; parts that contribute to no
mark point are counted.

```
offPoint = { idle, total, ratio, samples }   // samples = the offending sentences
```

- **ratio ≥ 0.40** → charge Rule 2, deduct half the question's marks.
- `null` when the answer is a single sentence — the splitter cannot see
  redundancy there, so fall back to `wordCount`.
- Parts opening with `(a)`/`(b)`/`(c)` are exempt: bound to a sub-question by
  structure, they can be wrong but never off point.

### `wordCount` — Rule 2, secondary

`wordCount > marks * 15` means the answer is long for its weight (a 2-mark
answer should be about 30 words, i.e. two sentences). Treat as a hint, not a
verdict — True/False tables with reasons legitimately run longer.

### Rule 3 is not detectable

Nothing mechanical tells you the tense disagrees with the question. Read it.

## Workflow

1. **Pull the item.**
   ```bash
   curl -s -H "X-Admin-Pin: $ADMIN_PIN" \
     http://127.0.0.1:2021/api/epaper/sessions/<id> | node -e '...'
   ```
   Each OEQ item carries `liftRatio`, `liftExpected`, `offPoint`, `wordCount`,
   `suggest` and `points[]`. If the app is not reachable, read
   `~/kidreminder/kidreminder.db` directly with `node:sqlite`.

2. **Charge the rules.** `suggest.liftZero` and `suggest.simplifyHalf` are the
   detectors' verdicts; `suggest` is only a default while the session is
   unreviewed (`points.some(p => p.finalHit === 0 || p.finalHit === 1)` tells you
   whether a human has already decided). Rule 3 you set by reading.

3. **Check the content points yourself.** Open the answer against each mark
   point's **description**, not its keywords. Whole families of wrong answers
   pass the keyword test because the keyword list is a synonym set — our lists
   average 93 characters for this paper and are the loosest in the set.

4. **Save.**
   ```bash
   curl -s -X POST -H "X-Admin-Pin: $ADMIN_PIN" -H "Content-Type: application/json" \
     -d '{"items":[{"itemId":123,"points":[{"markPointId":9,"hit":true}],
                    "liftZero":false,"simplifyHalf":true,"tenseError":false}]}' \
     http://127.0.0.1:2021/api/epaper/sessions/<id>/review
   ```

5. **Verify against the teacher.** If a marked script exists, compare section
   totals first, then per question, then per mark point. Report every remaining
   difference — do not smooth it over.

## Scoring, exactly

From `epaperComputeScore()`:

```js
if (lift_zero)             score = 0;
else {
  penalty = 0;
  if (simplify_half) penalty += marks * 0.5;
  if (tense_error)   penalty += 1;
  score = Math.max(0, hits - penalty);
}
```

`hits` = number of mark points earned (`final_hit` if set, else `auto_hit`).

## When reconciling with a teacher's marked PDF

Teacher marks arrive as **ink annotations**, not text. Extract them with:

```python
import fitz
d = fitz.open("teacher.pdf")
for i, p in enumerate(d, 1):
    for a in p.annots():                 # (15, 'Ink')
        for stroke in a.vertices:
            ...
```

then render the pages (`get_pixmap(dpi=140)`) and **read the marks visually** —
the written score sits in the margin beside each question. Crop and zoom
(`get_pixmap(dpi=300, clip=fitz.Rect(...))`) when a handwritten number is
ambiguous. Assuming a ✓ means full marks cost me 0.5 on Q75; the margin number
is the authority.

## Calibration history

Keeping this honest matters more than looking good. On the Rulang script:

| | OEQ total |
|---|---|
| Keyword matcher + AI review | 15/20 |
| After applying rules 1–4 | **8/20** |
| Teacher | **8/20** |

Two false-positive lessons, both from scanning the six papers done so far:

- A part opening with `(a)`/`(b)` is bound to that sub-question. `"a) The author
  felt nervous."` was flagged off point although it plainly answers part (a) —
  the keyword list simply read `terrifi|scared|afraid`, not `nervous`. **Wrong is
  not the same as irrelevant.**
- Matching no mark point is not enough to call something padding — require it to
  be lifted too. Before that condition, 13 answers across six papers were
  flagged; afterwards, 2, and both read as genuine filler.

Scan every completed paper after changing any rule. Compare the flagged set
against the teacher's marks where they exist.
