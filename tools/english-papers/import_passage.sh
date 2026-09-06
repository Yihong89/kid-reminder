#!/usr/bin/env bash
# Re-import one paper after a subagent filled its `passage`, so the passage
# column is written to the Mac mini DB. Idempotent (UPDATE + preserves history).
# Usage: ./import_passage.sh <slug>
set -euo pipefail
cd "$(dirname "$0")"
SLUG="$1"
JSON="$SLUG-2025-questions.json"
MINI="robot@192.168.0.12"
echo "=== validate $JSON ==="
python3 validate.py "$JSON" 2>&1 | tail -2
echo "=== copy to Mac mini ==="
scp "$JSON" "$MINI:/Users/robot/kidreminder/$JSON"
echo "=== import (real) ==="
ssh "$MINI" "cd /Users/robot/kidreminder && /Users/robot/nodejs/bin/node epaper-import.js $JSON" 2>&1 | tail -3
echo "=== passage check ==="
ssh "$MINI" "/Users/robot/nodejs/bin/node -e \"const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync('/Users/robot/kidreminder/kidreminder.db');const r=db.prepare(\\\"SELECT length(passage) plen FROM epaper_questions WHERE section='comprehension_oeq' AND paper_key='$SLUG-2025' LIMIT 1\\\").get();console.log('  passage_len=', r?r.plen:0);\"" 2>&1 | tail -1
