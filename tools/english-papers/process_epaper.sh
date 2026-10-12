#!/usr/bin/env bash
# Validate + stage-import one english paper's questions JSON and its images to Mac mini.
# Usage: process_epaper.sh <slug>   e.g. ./process_epaper.sh mgs
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: process_epaper.sh <slug>}"

# Year comes from the JSON's own filename -- it used to be hardcoded to 2025,
# which silently ruled out any other year (the P5 2024 EOY set).
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
python3 validate.py "$JSON" 2>&1 | tail -3

echo "=== copy $JSON to Mac mini ==="
scp "$JSON" "$MINI:/Users/robot/kidreminder/$JSON"

# Both images, every time: the Text 1 poster AND the comprehension passage.
# This script used to copy only the poster, so the passage image (which the
# comprehension_oeq questions reference) was scp'd by hand and easily missed.
for kind in q21 passage; do
  IMG="$IMGDIR/$SLUG-$YEAR-$kind.png"
  if [ -f "$IMG" ]; then
    scp "$IMG" "$MINI:/Users/robot/kidreminder/epaper-images/$SLUG-$YEAR-$kind.png"
    echo "  copied $kind image"
  else
    echo "  (no $kind image at $IMG)"
  fi
done

echo "=== dry-run import on Mac mini ==="
ssh "$MINI" "cd /Users/robot/kidreminder && /Users/robot/nodejs/bin/node epaper-import.js $JSON --dry-run" 2>&1 | tail -4
