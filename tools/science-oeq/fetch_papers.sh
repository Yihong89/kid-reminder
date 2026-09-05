#!/bin/bash
# Download the 2025 P6 Science prelim papers from Serious About School.
#
# These are freely-distributed school prelim papers, fetched for one child's
# personal study. Deliberately sequential with a delay between requests — ten
# files fetched once is not a crawl, and there is no reason to hammer the host.
# Already-downloaded files are skipped, so re-running is cheap and safe.
#
# Question paper AND answers are in the same PDF for the 2025 set.
#
# Usage:
#   bash fetch_papers.sh            # download into ./papers/
#   DEST=/some/dir bash fetch_papers.sh
set -euo pipefail
cd "$(dirname "$0")"

DEST="${DEST:-papers}"
DELAY="${DELAY:-3}"
BASE="https://seriousaboutschool.com/uploads/wysiwyg"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

mkdir -p "$DEST"

# "<slug>|<remote filename stem>" — the trailing number is the host's own timestamp suffix.
PAPERS=(
  "acs-junior|ACS Junior_1765262028"
  "ai-tong|Ai Tong_1765262042"
  "catholic-high|Catholic High_1765262056"
  "henry-park|Henry Park_1765262069"
  "mgs-paya-lebar|MGS Paya Lebar_1765263297"
  "nan-hua|Nan Hua_1765263312"
  "nanyang|Nanyang_1765263328"
  "raffles-girls|Raffles Girls_1765263358"
  "scgs|SCGS_1765262127"
  "tao-nan|Tao Nan_1765263378"
)

ok=0; skip=0; fail=0
for entry in "${PAPERS[@]}"; do
  slug="${entry%%|*}"
  stem="${entry##*|}"
  out="$DEST/2025-$slug.pdf"

  if [ -s "$out" ]; then
    echo "SKIP  $slug (already have $(du -h "$out" | cut -f1))"
    skip=$((skip + 1))
    continue
  fi

  # The host's filenames contain spaces; curl rejects a raw space in a URL
  # ("Malformed input to a URL function"), so encode them. Only spaces occur
  # in these names — no other characters need escaping.
  url="$BASE/2025-P6-Science-Prelim Exam-$stem.pdf"
  url="${url// /%20}"
  printf "GET   %-16s " "$slug"

  # --fail so an HTML error page never lands on disk as a .pdf; write to .tmp
  # first so an interrupted download can't leave a truncated file that the
  # "already have" check above would then skip forever.
  if curl -sS --fail --location --max-time 120 \
          --user-agent "$UA" \
          --output "$out.tmp" \
          "$url"; then
    mv "$out.tmp" "$out"
    echo "ok  $(du -h "$out" | cut -f1)"
    ok=$((ok + 1))
  else
    rm -f "$out.tmp"
    echo "FAILED"
    fail=$((fail + 1))
  fi

  sleep "$DELAY"
done

echo
echo "downloaded=$ok skipped=$skip failed=$fail  ->  $DEST/"
