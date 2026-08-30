#!/bin/bash
# Weekly sync: pull the kid's wrong-answers.md from the private
# GeorgeXL26/english-master repo, parse it, and import any new questions into
# the production english_questions table. Safe to re-run — import.js is
# idempotent on source_number, so already-imported questions are skipped.
#
# Installed on the Mac Mini as a launchd job (see
# com.kidreminder.wronganswers-sync.plist) that runs this on a weekly
# schedule. See README.md for the token setup and install steps.
set -euo pipefail
cd "$(dirname "$0")"

TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.config/kidreminder/wrong-answers-token}"
if [ ! -f "$TOKEN_FILE" ]; then
  echo "[sync] ERROR: token file not found at $TOKEN_FILE" >&2
  exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")

echo "[sync] $(date '+%Y-%m-%d %H:%M:%S') pulling wrong-answers.md ..."
# Fetch to a temp file first — if this curl fails, `set -e` aborts before the
# mv below, so a bad pull can never clobber the last-known-good copy.
curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github.raw+json" \
  "https://api.github.com/repos/GeorgeXL26/english-master/contents/English/wrong-answers.md" \
  -o wrong-answers.md.tmp
mv wrong-answers.md.tmp wrong-answers.md

echo "[sync] parsing ..."
python3 parse_wrong_answers.py wrong-answers.md

echo "[sync] importing into production db ..."
# launchd jobs don't source shell profiles, so PATH may not have node on it —
# same reason the server's own launchd plist points at an absolute node path.
NODE_BIN="${NODE_BIN:-$HOME/nodejs/bin/node}"
[ -x "$NODE_BIN" ] || NODE_BIN=node
DB_PATH="${DB_PATH:-$HOME/kidreminder/kidreminder.db}" "$NODE_BIN" import.js

echo "[sync] done."
