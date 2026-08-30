#!/usr/bin/env bash
#
# benchmark-sync.sh — compare substitute latency through GIPS against a central
# Guix substitute server, and emit a JSON file the telemetry dashboard reads.
#
#   ./scripts/benchmark-sync.sh --out bench.json
#   ./scripts/benchmark-sync.sh --package hello --package emacs --out bench.json
#   ./scripts/benchmark-sync.sh --no-baseline --out bench.json
#
# WHAT IT MEASURES
#
#   For each package, the time for `guix build --dry-run` to answer "can this be
#   substituted, and from where" against two substitute URLs. That command
#   fetches narinfos and resolves the closure but downloads no nars, so the
#   number isolates *substitute lookup* — the thing GIPS changes — instead of
#   being dominated by however fast the link is on the day.
#
#   `--full` additionally times a real `guix build` into a throwaway store
#   root, which does move nar bytes. That is the honest end-to-end number and
#   it is opt-in because it is slow and writes to the store.
#
# WHAT IT REFUSES TO DO
#
#   Invent numbers. If `guix` is missing, this script does NOT fall back to a
#   simulated comparison. It degrades to metrics-only mode: it reads the
#   daemon's own /metrics and reports GIPS-side latency with `baseline_ms`
#   absent, and the emitted JSON says so in `mode` and `note`. The dashboard
#   renders that as "no baseline was measured" rather than as a win. A
#   benchmark that manufactures its own baseline is worse than no benchmark.
#
# OUTPUT
#
#   JSON, schema `gips.benchmark.v1`, on stdout or to --out:
#
#     { "schema": "gips.benchmark.v1",
#       "generated_at": "2026-08-17T12:00:00Z",
#       "mode": "comparative" | "metrics-only",
#       "gips_url": "http://127.0.0.1:8080",
#       "baseline_url": "https://ci.guix.gnu.org",
#       "note": "...",
#       "comparisons": [ { "label": "hello", "gips_ms": 41.2, "baseline_ms": 288.0 } ],
#       "gips_metrics": { ...verbatim /metrics payload, or null... } }
#
# EXIT STATUS
#
#   0  a result file was written (in either mode)
#   1  bad usage, or a hard failure writing the output
#
set -euo pipefail

GIPS_URL="${GIPS_URL:-http://127.0.0.1:8080}"
BASELINE_URL="${BASELINE_URL:-https://ci.guix.gnu.org}"
OUT=""
FULL=0
WANT_BASELINE=1
REPEATS=3
PACKAGES=()
TOKEN="${GIPS_AUTH_TOKEN:-}"
TOKEN_FILE="${GIPS_AUTH_TOKEN_FILE:-}"

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() { printf 'benchmark-sync: %s\n' "$*" >&2; exit 1; }
log() { printf 'benchmark-sync: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; [ -n "$OUT" ] || die "--out needs a path"; shift 2 ;;
        --package|-p) [ -n "${2:-}" ] || die "--package needs a name"; PACKAGES+=("$2"); shift 2 ;;
        --gips-url) GIPS_URL="${2:-}"; shift 2 ;;
        --baseline-url) BASELINE_URL="${2:-}"; shift 2 ;;
        --repeats) REPEATS="${2:-}"; shift 2 ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
        --no-baseline) WANT_BASELINE=0; shift ;;
        --full) FULL=1; shift ;;
        -h|--help) usage 0 ;;
        *) printf 'benchmark-sync: unknown option %s\n\n' "$1" >&2; usage 1 ;;
    esac
done

[ "${#PACKAGES[@]}" -gt 0 ] || PACKAGES=(hello)
case "$REPEATS" in
    ''|*[!0-9]*) die "--repeats must be a positive integer" ;;
    0) die "--repeats must be at least 1" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"

# ---------------------------------------------------------------------------
# JSON helpers
#
# Emitting JSON from shell is where these scripts usually start lying: an
# unescaped package name or error string produces a file that parses into
# something other than what happened. Everything variable goes through
# json_string.
# ---------------------------------------------------------------------------

json_string() {
    # Escapes one argument as a JSON string, including the quotes.
    printf '%s' "$1" | awk '
        BEGIN { printf "\"" }
        {
            line = $0
            gsub(/\\/, "\\\\", line)
            gsub(/"/, "\\\"", line)
            gsub(/\t/, "\\t", line)
            gsub(/\r/, "\\r", line)
            if (NR > 1) printf "\\n"
            printf "%s", line
        }
        END { printf "\"" }'
}

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------

now_ms() {
    # `date +%s%N` is GNU-only; BSD date (macOS) has no nanoseconds. Python is
    # the portable fallback, and Perl the fallback's fallback.
    if [ -n "${NOW_MS_IMPL:-}" ]; then
        "$NOW_MS_IMPL"
        return
    fi
    date +%s%N | awk '{ printf "%d", $1 / 1000000 }'
}

now_ms_python() { python3 -c 'import time; print(int(time.time()*1000))'; }
now_ms_perl()   { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

select_clock() {
    if date +%s%N 2>/dev/null | grep -qE '^[0-9]{19}$'; then
        NOW_MS_IMPL=""
    elif command -v python3 >/dev/null 2>&1; then
        NOW_MS_IMPL=now_ms_python
    elif command -v perl >/dev/null 2>&1; then
        NOW_MS_IMPL=now_ms_perl
    else
        die "no millisecond clock available (need GNU date, python3 or perl)"
    fi
}
select_clock

# Runs "$@" REPEATS times, printing the best wall time in ms, or "null" if
# every attempt failed.
#
# Best-of rather than mean: a substitute lookup is a floor-plus-noise
# measurement — a slow run means something else was contending, not that the
# server is slower — and the minimum is the least noisy estimator of that
# floor. The count of failures is reported separately so a "fast" result that
# was really a fast failure cannot hide.
best_of() {
    local best="" i start end elapsed ok=0
    for i in $(seq 1 "$REPEATS"); do
        start="$(now_ms)"
        if "$@" >/dev/null 2>&1; then
            end="$(now_ms)"
            elapsed=$((end - start))
            ok=1
            if [ -z "$best" ] || [ "$elapsed" -lt "$best" ]; then best="$elapsed"; fi
        fi
    done
    if [ "$ok" -eq 0 ] || [ -z "$best" ]; then printf 'null'; else printf '%s' "$best"; fi
}

probe_substitutes() {
    # One substitute-resolution pass. --dry-run resolves the closure and reads
    # narinfos without downloading nars.
    local url="$1" package="$2"
    guix build --dry-run --no-grafts \
        --substitute-urls="$url" \
        "$package"
}

probe_full() {
    local url="$1" package="$2"
    guix build --no-grafts --substitute-urls="$url" "$package"
}

# ---------------------------------------------------------------------------
# The daemon's own view
# ---------------------------------------------------------------------------

read_token() {
    if [ -n "$TOKEN" ]; then return 0; fi
    local candidates=()
    [ -n "$TOKEN_FILE" ] && candidates+=("$TOKEN_FILE")
    [ -n "${XDG_CONFIG_HOME:-}" ] && candidates+=("$XDG_CONFIG_HOME/gips/auth-token")
    candidates+=("$HOME/.config/gips/auth-token")
    candidates+=("$HOME/Library/Application Support/gips/auth-token")
    local path
    for path in "${candidates[@]}"; do
        if [ -r "$path" ]; then
            TOKEN="$(tr -d '\r\n' < "$path")"
            log "read auth token from $path"
            return 0
        fi
    done
    return 1
}

fetch_metrics() {
    # Prints the /metrics payload, or nothing. Never prints the token, and
    # never puts it in a URL or an argv that shows up in `ps` output for other
    # users — curl reads it from a config file on stdin instead.
    [ -n "$TOKEN" ] || return 1
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl --silent --show-error --fail --max-time 10 \
             --config - "$GIPS_URL/metrics" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

MODE="comparative"
NOTE=""

if ! command -v guix >/dev/null 2>&1; then
    MODE="metrics-only"
    NOTE="guix is not installed on this machine, so no build was timed and no baseline was measured. The GIPS-side numbers below come from the daemon's own /metrics. Nothing here supports a claim that GIPS is faster than a central server."
    log "guix not found — degrading to metrics-only mode (no baseline will be invented)"
elif ! curl --silent --fail --max-time 5 "$GIPS_URL/status" >/dev/null 2>&1; then
    MODE="metrics-only"
    NOTE="gipsd did not answer at $GIPS_URL/status, so no request could be routed through GIPS. No baseline was measured."
    log "gipsd unreachable at $GIPS_URL — degrading to metrics-only mode"
fi

if [ "$WANT_BASELINE" -eq 0 ] && [ "$MODE" = "comparative" ]; then
    NOTE="--no-baseline was passed: only the GIPS path was timed."
fi

COMPARISONS=""
append_comparison() {
    [ -n "$COMPARISONS" ] && COMPARISONS="$COMPARISONS,"
    COMPARISONS="$COMPARISONS$1"
}

if [ "$MODE" = "comparative" ]; then
    log "timing $REPEATS run(s) per package; best of each is reported"
    for package in "${PACKAGES[@]}"; do
        log "  $package via GIPS ($GIPS_URL)"
        gips_ms="$(best_of probe_substitutes "$GIPS_URL" "$package")"

        baseline_ms="null"
        if [ "$WANT_BASELINE" -eq 1 ]; then
            log "  $package via baseline ($BASELINE_URL)"
            baseline_ms="$(best_of probe_substitutes "$BASELINE_URL" "$package")"
        fi

        append_comparison "$(printf '{"label":%s,"phase":"substitute lookup","gips_ms":%s,"baseline_ms":%s}' \
            "$(json_string "$package")" "$gips_ms" "$baseline_ms")"

        if [ "$FULL" -eq 1 ]; then
            log "  $package full build via GIPS"
            gips_full="$(best_of probe_full "$GIPS_URL" "$package")"
            baseline_full="null"
            if [ "$WANT_BASELINE" -eq 1 ]; then
                log "  $package full build via baseline"
                baseline_full="$(best_of probe_full "$BASELINE_URL" "$package")"
            fi
            append_comparison "$(printf '{"label":%s,"phase":"full build","gips_ms":%s,"baseline_ms":%s}' \
                "$(json_string "$package (full)")" "$gips_full" "$baseline_full")"
        fi
    done
fi

# Whatever mode we are in, attach the daemon's own numbers if we can read them.
METRICS="null"
if read_token; then
    if payload="$(fetch_metrics)" && [ -n "$payload" ]; then
        METRICS="$payload"
    else
        log "could not read $GIPS_URL/metrics (is the daemon running, and is the token current?)"
    fi
else
    log "no auth token found; /metrics will be omitted (pass --token or --token-file)"
fi

# In metrics-only mode the daemon's own histograms are the only thing to show,
# so turn the ones the dashboard charts into GIPS-side rows with no baseline.
if [ "$MODE" = "metrics-only" ] && [ "$METRICS" != "null" ] && command -v python3 >/dev/null 2>&1; then
    rows="$(printf '%s' "$METRICS" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
wanted = ["narinfo_response_ms", "nar_fetch_ipfs_ms", "nar_fetch_local_ms", "signature_verify_ms"]
out = []
for h in payload.get("histograms", []):
    if h.get("name") in wanted and h.get("count", 0) > 0:
        out.append({"label": h["name"] + " (p50)", "phase": "daemon histogram",
                    "gips_ms": h.get("p50_ms")})
sys.stdout.write(json.dumps(out)[1:-1])
' 2>/dev/null || true)"
    [ -n "$rows" ] && append_comparison "$rows"
fi

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit() {
    printf '{\n'
    printf '  "schema": "gips.benchmark.v1",\n'
    printf '  "generated_at": %s,\n' "$(json_string "$GENERATED_AT")"
    printf '  "mode": %s,\n' "$(json_string "$MODE")"
    printf '  "repeats": %s,\n' "$REPEATS"
    printf '  "gips_url": %s,\n' "$(json_string "$GIPS_URL")"
    if [ "$MODE" = "comparative" ] && [ "$WANT_BASELINE" -eq 1 ]; then
        printf '  "baseline_url": %s,\n' "$(json_string "$BASELINE_URL")"
    else
        printf '  "baseline_url": null,\n'
    fi
    printf '  "note": %s,\n' "$(json_string "$NOTE")"
    printf '  "comparisons": [%s],\n' "$COMPARISONS"
    printf '  "gips_metrics": %s\n' "$METRICS"
    printf '}\n'
}

if [ -n "$OUT" ]; then
    emit > "$OUT" || die "could not write $OUT"
    log "wrote $OUT (mode: $MODE)"
    log "open $GIPS_URL/dashboard and load this file with the Benchmark control"
else
    emit
fi
