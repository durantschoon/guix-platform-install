#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ledger="$repo_root/.oracle-validation/timings.tsv"

timing_files=()
[ -s "$ledger" ] && timing_files+=("$ledger")
while IFS= read -r path; do
  timing_files+=("$path")
done < <(find "$repo_root/.oracle-validation/runs" -mindepth 2 -maxdepth 2 \
  -name timings.tsv -type f 2>/dev/null | sort)

if [ "${#timing_files[@]}" -eq 0 ]; then
  echo "No timing samples recorded yet."
  exit 0
fi

echo "Duration history (seconds):"
awk -F '\t' '
  $3 == "passed" || $3 == "failed" {
    phase[$2] = 1
    count[$2]++
    if ($3 == "failed") failures[$2]++
    value[$2, count[$2]] = $4 + 0
  }
  END {
    printf "%-24s %7s %8s %9s %9s %9s\n", "phase", "samples", "failures", "median", "p90", "latest"
    for (p in phase) {
      n = count[p]
      for (i = 1; i <= n; i++) sorted[i] = value[p, i]
      for (i = 2; i <= n; i++) {
        x = sorted[i]; j = i - 1
        while (j >= 1 && sorted[j] > x) { sorted[j + 1] = sorted[j]; j-- }
        sorted[j + 1] = x
      }
      median = sorted[int((n + 1) / 2)]
      p90_index = int(n * 0.9); if (p90_index < n * 0.9) p90_index++
      if (p90_index < 1) p90_index = 1
      printf "%-24s %7d %8d %9d %9d %9d\n", p, n, failures[p], median, sorted[p90_index], value[p, n]
      delete sorted
    }
  }
' "${timing_files[@]}"

echo
echo "Predictions use the median; p90 is the conservative planning bound."
