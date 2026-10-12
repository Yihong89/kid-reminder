#!/usr/bin/env bash
# Re-import one paper after a subagent filled its `passage`, so the passage
# column is written to the Mac mini DB. Idempotent (UPDATE + preserves history).
# Usage: ./import_passage.sh <slug>
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: import_passage.sh <slug>}"

# Year from the JSON's filename -- was hardcoded to 2025 (see process_epaper.sh).
mapfile -t MATCHES < <(ls -1 "$SLUG"-*-questions.json 2>/dev/null || true)
if [ "${#MATCHES[@]}" -eq 0 ]; then
  echo "no $SLUG-<year>-questions.json here"; exit 1
elif [ "${#MATCHES[@]}" -gt 1 ]; then
  echo "ambiguous: ${MATCHES[*]} -- keep one year per slug"; exit 1
fi
JSON="${MATCHES[0]}"
YEAR="$(basename "$JSON" | sed -E 's/^.*-([0-9]{4})-questions\.json$/\1/')"

MINI="robot@192.168.0.12"
IMGDIR="../../backend/epaper-images"

echo "=== validate $JSON (year $YEAR) ==="
python3 validate.py "$JSON" 2>&1 | tail -2

echo "=== copy to Mac mini ==="
scp "$JSON" "$MINI:/Users/robot/kidreminder/$JSON"
for kind in q21 passage; do
  IMG="$IMGDIR/$SLUG-$YEAR-$kind.png"
  [ -f "$IMG" ] && scp "$IMG" "$MINI:/Users/robot/kidreminder/epaper-images/$SLUG-$YEAR-$kind.png" \
    && echo "  copied $kind image"
done

echo "=== import (real) ==="
ssh "$MINI" "cd /Users/robot/kidreminder && /Users/robot/nodejs/bin/node epaper-import.js $JSON" 2>&1 | tail -3

echo "=== passage check ==="
ssh "$MINI" "/Users/robot/nodejs/bin/node -e \"const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync('/Users/robot/kidreminder/kidreminder.db');const r=db.prepare(\\\"SELECT length(passage) plen, count(*) n FROM epaper_questions WHERE section='comprehension_oeq' AND paper_key='$SLUG-$YEAR' \\\").get();console.log('  passage_len=', r?r.plen:0, ' oeq items=', r?r.n:0);\"" 2>&1 | tail -1
