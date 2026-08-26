#!/usr/bin/env bash
set -uo pipefail

phase=${1:?timing phase is required}
shift
repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ledger="$repo_root/.oracle-validation/timings.tsv"
mkdir -p "$(dirname "$ledger")"

prediction=$(
  awk -F '\t' -v phase="$phase" \
    '$2 == phase && ($3 == "passed" || $3 == "failed") { print $4 }' \
    "$ledger" 2>/dev/null | sort -n | \
    awk '{ value[NR]=$1 } END { if (NR) print value[int((NR+1)/2)] }'
)
if [ -n "$prediction" ]; then
  echo "[TIME] $phase predicted: ${prediction}s (historical median)"
else
  echo "[TIME] $phase predicted: insufficient history"
fi

started=$(date +%s)
"$@"
status=$?
ended=$(date +%s)
actual=$((ended - started))
if [ "$status" -eq 0 ]; then outcome=passed; else outcome=failed; fi
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$outcome" "$actual" command \
  >>"$ledger"
if [ -n "$prediction" ]; then
  echo "[TIME] $phase actual: ${actual}s; delta from median: $((actual - prediction))s"
else
  echo "[TIME] $phase actual: ${actual}s; first sample recorded"
fi
exit "$status"
