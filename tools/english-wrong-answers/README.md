# english-wrong-answers

One-off import pipeline for the 英语错题练习 (English wrong-answer practice)
feature: turns the kid's own mistake log into rows in `english_questions`.

## Source

`wrong-answers.md` comes from a **private** GitHub repo
(`GeorgeXL26/english-master`, `English/wrong-answers.md`) — a running log of
real mistakes from schoolwork/revision papers, written up with the correct
answer and a short explanation each time. Pull the current copy with:

```bash
gh api repos/GeorgeXL26/english-master/contents/English/wrong-answers.md --jq '.content' \
  | base64 -d > wrong-answers.md
```

It's gitignored here (along with the JSON files derived from it) — this repo
is public, and that content is a real child's personal schoolwork.

## Usage

```bash
python3 parse_wrong_answers.py wrong-answers.md   # -> parsed-questions.json, unparsed-questions.json
node import.js                                     # imports parsed-questions.json into kidreminder.db
```

`import.js` is idempotent (unique index on `source_number`) — re-running it
after pulling a fresh `wrong-answers.md` only inserts genuinely new
questions.

## What gets skipped

- ~40 entries per run are "meta-only": the log recorded "student wrote X,
  correct answer is Y" for a comprehension-cloze/editing passage without
  copying the passage sentence itself, so there's no real prompt to show the
  kid. `import.js`'s `META_MARKERS` list catches the phrasings seen so far
  ("Comprehension Cloze", "Editing —", "not captured", …) — if a future pull
  adds a new phrasing that slips through, delete the bad row via the admin
  panel's 英语错题 tab and add the marker here.
- A handful of items (multi-item numbered answer lists, cloze items that
  reference an external word bank never included in the log) don't match any
  of the parser's known formats; see `unparsed-questions.json` for what was
  skipped and why, on your local run.

## `needs_audio` classification

Only `fill_blank` questions can get a 🔊 replay-sentence button (mcq and
sentence_transform never do, by product decision). The heuristic:
single-word answer, 6+ letters, not ending in "-ing" (those are almost always
a verb-tense conjugation, not a spelling-worthy vocabulary word). It's
imperfect on purpose — wrong calls are a one-checkbox fix in the admin
panel's edit dialog, not worth hand-tuning the script for.
