#!/usr/bin/env bash
# Validate + stage-import one english paper's questions JSON and poster image to Mac mini.
# Usage: process_epaper.sh <slug>   e.g. ./process_epaper.sh mgs
set -euo pipefail
cd "$(dirname "$0")"
SLUG="$1"
JSON="$SLUG-2025-questions.json"
IMG="../../backend/epaper-images/$SLUG-2025-q21.png"
MINI="robot@192.168.0.12"

echo "=== validate $JSON ==="
python3 validate.py "$JSON" 2>&1 | tail -3

echo "=== copy $JSON + poster image to Mac mini ==="
scp "$JSON" "$MINI:/Users/robot/kidreminder/$JSON"
if [ -f "$IMG" ]; then
  scp "$IMG" "$MINI:/Users/robot/kidreminder/epaper-images/$SLUG-2025-q21.png"
else
  echo "  (no poster image at $IMG)"
fi

echo "=== dry-run import on Mac mini ==="
ssh "$MINI" "cd /Users/robot/kidreminder && /Users/robot/nodejs/bin/node epaper-import.js $JSON --dry-run" 2>&1 | tail -4
