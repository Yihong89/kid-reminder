---
name: marking-synthesis
description: >-
  Mark Singapore primary English Paper 2 sentence synthesis (Booklet B, the 5-question / 10-mark rewrite section) the way a school teacher does. Use when marking, reviewing or calibrating sentence synthesis; when a rewrite changes the meaning, drops punctuation, or repeats the stem the question already gave; when deciding between full, half and zero marks; when a teacher's marked script must be reconciled with the app's score. Triggers on — synthesis, 句子改写, 改写句子, sentence synthesis, meaning changed, 改卷, 批改, epaper synthesis review, teacher's marking differs.
---

# Marking sentence synthesis like a teacher

Synthesis asks the pupil to rewrite given sentence(s) using a supplied word,
keeping the meaning, in one sentence. The app used to mark it all-or-nothing:
match the model answer and score full marks, otherwise zero. The teacher's script
shows that is wrong in both directions — he gave partial credit, and he failed an
answer that used every word of the model answer.

Read this before touching any synthesis score.

## The standard

| # | Rule | Effect | Teacher's words |
|---|------|--------|-----------------|
| 1 | **Meaning changed** by the rewrite | **Question scores 0** | "(meaning changed)" |
| 2 | **Grammar or punctuation error** | **Lose 1 mark** | inserted the missing comma, gave 1/2 |
| 3 | Faithful rewrite, even if wording differs from the model | **Full marks** | ✓✓ on two answers that did not match the key verbatim |

### Rule 1 — meaning, not wording

The trap is a rewrite that keeps every word but moves a phrase, so the phrase now
attaches to something else.

> Original: *The mouse ate the cheese on the plate.*
> Prompt: *The cheese ______________.*
> Model: *on the plate was eaten by the mouse*
> Pupil: *The cheese was eaten by the mouse **on the plate**.* → **0/2**

Every word survives, but "on the plate" now describes the mouse rather than the
cheese. That is a different sentence. When a pupil's answer contains the model's
words in a different order, ask what each phrase now modifies before awarding
anything.

### Rule 2 — punctuation and grammar cost a mark

> Prompt: *Had Aidah ______________.*
> Pupil: *Had Aidah not moved away in time **she** would have been clawed by the cat.* → **1/2**

The teacher inserted a comma after "time". The rewrite is otherwise correct, so
it scores one of the two marks. This is the same shape as the comprehension "lose
1 mark for grammar/tense disagreeing" rule: **a fixed one-mark deduction, not a
zero**.

A comma after an introductory clause, subject-verb agreement, and a missing
full stop are the usual culprits.

### Rule 3 — be tolerant of everything the question itself supplied

The teacher accepted these at full marks:

| Q | Model answer | Pupil wrote | Teacher |
|---|---|---|---|
| 63 | *not to bring their mobile phones…* | *Mrs Chan told **her** pupils not to bring…* | **2/2** |
| 65 | *the players nor the coach was pleased…* | ***Neither** the players nor the coach was pleased…* | **2/2** |

The stem ("Mrs Chan told the pupils ___", "Neither ___") is printed on the paper,
so repeating it adds nothing and should not be charged. Likewise a possessive
that shifts with the reported speech ("the pupils" → "her pupils"). The app
handles this with a containment rule in `epaperGradeObjective(..., { tolerant:
true })` — keep it.

## Worked example — the whole section

Rulang 2025, session 53, teacher's marks against the app's:

| Q | Pupil wrote | Rules charged | Score | Teacher |
|---|---|---|---|---|
| 61 | *The cheese was eaten by the mouse on the plate.* | 1 | **0/2** | 0/2 ✓ |
| 62 | *Had Aidah not moved away in time she would have been clawed by the cat.* | 2 | **1/2** | 1/2 ✓ |
| 63 | *Mrs Chan told her pupils not to bring their mobile phones for the field trip the following day.* | 3 | **2/2** | 2/2 ✓ |
| 64 | *It was with great eagerness for the children to start their holiday.* | wrong structure | **0/2** | 0/2 ✓ |
| 65 | *Neither the players nor the coach was pleased with the referee's decisions.* | 3 | **2/2** | 2/2 ✓ |
| | | | **5/10** | **5/10** ✓ |

All five now agree. Before this standard was written up, the app scored the
section 8/10.

## Scoring, exactly

From `epaperComputeScore()`, the `section === "synthesis"` branch:

```js
if (syn_meaning_changed || !final_correct) score = 0;
else score = Math.max(0, marks - (syn_lang_error ? 1 : 0));
```

So `final_correct` still decides whether the rewrite is acceptable at all (the
auto-grader plus the sentence-level AI check, overridden by the parent), and the
two flags then adjust it.

## Store the answer in the form the pupil writes

The prompt shows the stem and the blank (*"The cheese \_\_\_\_."*), so a pupil
writes the **whole sentence**, and that is what gets stored and compared. Keep
the model answer in both forms:

```
on the plate was eaten by the mouse
  / The cheese on the plate was eaten by the mouse
```

The official answers for Q61, Q62 and Q64 all arrived as full sentences; our keys
held only the blank-fill fragment, which the tolerant containment rule happens to
accept but which makes the accepted-answer list harder to read and to check. The
official set confirmed all three of our strips — Q61 *on the plate was eaten by
the mouse*, Q62 *moved away in time, the cat would not have clawed her*, Q64
*eagerness that the children started their holiday*.

## The two flags are not auto-detected

Unlike the comprehension detectors, neither can be measured:

- **Meaning change** is not a keyword problem. The Q61 answer contains 100% of
  the model's words; only the structure is wrong.
- **Punctuation** differences are not comparable across two differently-worded
  sentences.

So both are checkboxes the parent sets, and neither is ever pre-ticked. Do not
try to infer them — ask, or read the answer.

## Workflow

1. **Check the auto verdict first.** `final_correct` comes from
   `epaperGradeObjective()` (exact after `normalizeEnglishAnswer`, plus the
   tolerant containment rule) and, for sentence rewrites that miss, an AI second
   opinion. It runs the moment the paper is submitted.
2. **Read the pupil's answer against the model and the prompt.** Decide: faithful?
   If not, is it wrong wording (0) or wrong structure (0)? If faithful, is there
   a punctuation or grammar error (−1)?
3. **Save.**
   ```bash
   curl -s -X POST -H "X-Admin-Pin: $ADMIN_PIN" -H "Content-Type: application/json" \
     -d '{"items":[{"itemId":3642,"finalCorrect":true,"meaningChanged":true}]}' \
     http://127.0.0.1:2021/api/epaper/sessions/<id>/review

   curl -s -X POST -H "X-Admin-Pin: $ADMIN_PIN" -H "Content-Type: application/json" \
     -d '{"items":[{"itemId":3643,"finalCorrect":true,"langError":true}]}' \
     http://127.0.0.1:2021/api/epaper/sessions/<id>/review
   ```
4. **Compare the section total with the teacher's** before moving on. Ours read
   5/10 against the teacher's 5/10; anything else means a rule was misapplied.

## Adjacent sections

Synthesis sits in Booklet B alongside **comprehension open-ended** (see the
`marking-comprehension-oeq` skill) and **editing**. Editing is a spelling and
grammar correction section and is marked strictly right or wrong — but note that
a derived form can be accepted where the key lists only one: the teacher took
"gratefulness" where the key had "gratitude".
