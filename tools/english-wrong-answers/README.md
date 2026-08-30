# english-wrong-answers

Import pipeline for the 英语错题练习 (English wrong-answer practice) feature:
turns the kid's own mistake log into rows in `english_questions`. Runs
automatically on a weekly schedule on the Mac Mini (see "Automated sync"
below) — the steps here are also how to run it by hand.

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

## Automated sync

`sync.sh` does the pull + parse + import in one step, straight against the
production db, and runs weekly via a launchd job on the Mac Mini — so new
entries the kid logs in the private repo show up in the app without anyone
re-running this by hand.

**Auth**: `GeorgeXL26/english-master` is a different individual's personal
repo, so a fine-grained PAT can't be scoped to it (GitHub only lets
fine-grained tokens target repos owned by yourself or an org you belong to —
collaborator access on someone else's personal repo doesn't help). Use a
**classic** PAT instead, scope `repo`, created by whichever account has
collaborator access:
[github.com/settings/tokens/new](https://github.com/settings/tokens/new).

**Setup on the Mac Mini** (one-time):
```bash
mkdir -p ~/.config/kidreminder && chmod 700 ~/.config/kidreminder
echo 'ghp_...' > ~/.config/kidreminder/wrong-answers-token && chmod 600 !$
mkdir -p ~/kidreminder/english-sync
# copy sync.sh, parse_wrong_answers.py, import.js into ~/kidreminder/english-sync/
cp com.kidreminder.wronganswers-sync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.kidreminder.wronganswers-sync.plist
```
Runs Sundays at 3am; logs to `~/kidreminder/english-sync/sync.log`. The token
file lives outside the deployed app directory and is never scp'd/committed —
only `sync.sh` reads it, via `GITHUB_TOKEN_FILE` (defaults to that path).

If the token expires or is revoked, generate a new one and overwrite the same
file — no need to touch the launchd job.

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
