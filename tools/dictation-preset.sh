#!/bin/bash
# Apply or clear the end-of-year revision preset for Chinese dictation.
#
#   ADMIN_PIN=1056 tools/dictation-preset.sh exam      # 期末复习
#   ADMIN_PIN=1056 tools/dictation-preset.sh restore   # 恢复默认
#   ADMIN_PIN=1056 tools/dictation-preset.sh status    # 只看当前值
#
# Override the server with BASE_URL (default http://127.0.0.1:2021), e.g. when
# running from a laptop rather than on the server itself:
#
#   BASE_URL=http://192.168.0.12:2021 ADMIN_PIN=1056 tools/dictation-preset.sh status
#
# See docs/dictation-settings.md for what each key means.
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:2021}"
PIN="${ADMIN_PIN:-}"
ACTION="${1:-status}"

# Locate a node binary. A non-interactive ssh session has neither ~/nodejs/bin
# nor homebrew on PATH, so fall back to the known install locations rather than
# making every caller pass NODE_BIN.
if [ -z "${NODE_BIN:-}" ]; then
  for cand in node "$HOME/nodejs/bin/node" /Users/robot/nodejs/bin/node /opt/homebrew/bin/node; do
    if command -v "$cand" >/dev/null 2>&1; then NODE_BIN="$cand"; break; fi
  done
fi
if [ -z "${NODE_BIN:-}" ]; then
  echo "node not found — set NODE_BIN=/path/to/node" >&2
  exit 1
fi

if [ "$ACTION" != "status" ] && [ -z "$PIN" ]; then
  echo "ADMIN_PIN is required for '$ACTION' (the settings endpoint needs the parent PIN)." >&2
  exit 1
fi

# Read the canonical defaults/limits straight from the server so this script can
# never drift from SETTING_DEFS.
fields_json=$(curl -sf -m 10 "$BASE_URL/api/settings")

case "$ACTION" in
  status)
    printf '%s' "$fields_json" | "$NODE_BIN" -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        for (const f of JSON.parse(s).fields)
          console.log("  " + f.key.padEnd(30) + " = " + String(f.value) + (f.type === "int" ? "   (" + f.min + "–" + f.max + ")" : ""));
      });'
    ;;
  exam)
    # Values chosen for the 2026 end-of-year exam; see docs/dictation-settings.md.
    body='{"settings":{
      "dictation.zh.size":50,
      "dictation.zh.priorityLevel":"P5",
      "dictation.zh.writeOnly":true,
      "dictation.zh.charCap":2
    }}'
    curl -sf -m 10 -X PATCH -H "Content-Type: application/json" \
      -H "X-Admin-Pin: $PIN" -d "$body" "$BASE_URL/api/settings"
    echo
    echo "期末复习配置已应用。"
    ;;
  restore)
    # Every key back to its SETTING_DEFS default, i.e. pre-setting behaviour.
    printf '%s' "$fields_json" | "$NODE_BIN" -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        const def = {
          "dictation.zh.size": 40,
          "dictation.zh.priorityLevel": "",
          "dictation.zh.writeOnly": false,
          "dictation.zh.charCap": 10,
        };
        const have = new Set(JSON.parse(s).fields.map(f => f.key));
        const settings = {};
        for (const [k, v] of Object.entries(def)) if (have.has(k)) settings[k] = v;
        process.stdout.write(JSON.stringify({ settings }));
      });' > /tmp/dictation-restore.json
    curl -sf -m 10 -X PATCH -H "Content-Type: application/json" \
      -H "X-Admin-Pin: $PIN" --data-binary @/tmp/dictation-restore.json "$BASE_URL/api/settings"
    echo
    rm -f /tmp/dictation-restore.json
    echo "已恢复默认（= 这些设置出现之前的行为）。"
    ;;
  *)
    echo "usage: ADMIN_PIN=xxxx $0 {exam|restore|status}" >&2
    exit 2
    ;;
esac
