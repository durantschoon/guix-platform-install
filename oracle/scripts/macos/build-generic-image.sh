#!/usr/bin/env bash
set -euo pipefail

# Reproducible macOS/ARM controller for an x86_64 generic Oracle QCOW2.
# The named container is retained so an interrupted build can restart with its
# populated Guix store layer instead of downloading/building from scratch.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
BUILD_NAME=${BUILD_NAME:-ov2-current}
CACHE_IMAGE="guix-oracle-build-cache:$BUILD_NAME"
if [ -z "${GUIX_BUILD_IMAGE:-}" ] && docker image inspect "$CACHE_IMAGE" >/dev/null 2>&1; then
  GUIX_BUILD_IMAGE=$CACHE_IMAGE
else
  GUIX_BUILD_IMAGE=${GUIX_BUILD_IMAGE:-metacall/guix:latest}
fi
CONTAINER_NAME="guix-oracle-build-$BUILD_NAME"
OUTPUT_DIR="$REPO_ROOT/.oracle-validation/builds/$BUILD_NAME"
OUTPUT_FILE="$OUTPUT_DIR/guix-oracle-generic.qcow2"
TIMING_FILE="$REPO_ROOT/.oracle-validation/timings.tsv"
timing_started=$(date +%s)
timing_status=failed
timing_prediction=$(
  awk -F '\t' '$2 == "image-build" && ($3 == "passed" || $3 == "failed") { print $4 }' \
    "$TIMING_FILE" 2>/dev/null | sort -n | awk '{ value[NR]=$1 } END { if (NR) print value[int((NR+1)/2)] }'
)
if [ -n "$timing_prediction" ]; then
  echo "[TIME] image-build predicted: ${timing_prediction}s (historical median)"
else
  echo "[TIME] image-build predicted: insufficient history"
fi
record_timing() {
  timing_ended=$(date +%s)
  timing_actual=$((timing_ended - timing_started))
  mkdir -p "$(dirname "$TIMING_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" image-build "$timing_status" \
    "$timing_actual" "$BUILD_NAME" >>"$TIMING_FILE"
  if [ -n "$timing_prediction" ]; then
    echo "[TIME] image-build actual: ${timing_actual}s; delta from median: $((timing_actual - timing_prediction))s"
  else
    echo "[TIME] image-build actual: ${timing_actual}s; first sample recorded"
  fi
}
trap record_timing EXIT

case "$BUILD_NAME" in
  *[!A-Za-z0-9_-]*|'')
    echo "[ERROR] BUILD_NAME must contain only letters, digits, _ or -" >&2
    exit 2
    ;;
esac

if [ -e "$REPO_ROOT/oracle/image/authorized-key.pub" ]; then
  echo "[ERROR] Refusing generic build: oracle/image/authorized-key.pub exists" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

if [ -s "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE.sha256" ]; then
  echo "[OK] Generic image already present: $OUTPUT_FILE"
  (cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$OUTPUT_FILE.sha256")")
  timing_status=cache-hit
  exit 0
fi

run_build() {
  docker run --name "$CONTAINER_NAME" -t \
    --security-opt seccomp=unconfined \
    -v "$REPO_ROOT:/src:ro" \
    -v "$OUTPUT_DIR:/out" \
    -w /src \
    "$GUIX_BUILD_IMAGE" /bin/sh -lc '
      result=$(guix system image --system=x86_64-linux \
        -t qcow2 --image-size=50G oracle/image/oracle-image.scm) || exit $?
      cp --sparse=always "$result" /out/guix-oracle-generic.qcow2
      cd /out || exit $?
      sha256sum guix-oracle-generic.qcow2 \
        > guix-oracle-generic.qcow2.sha256
      printf "%s\n" "$result" > /out/store-path.txt
    '
}

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
  case "$state" in
    running)
      echo "[OK] Build is already running in $CONTAINER_NAME"
      docker logs -f "$CONTAINER_NAME"
      ;;
    exited|created)
      echo "Restarting retained build container: $CONTAINER_NAME"
      docker start -a "$CONTAINER_NAME"
      ;;
    *)
      echo "[ERROR] Unexpected container state $state for $CONTAINER_NAME" >&2
      exit 2
      ;;
  esac
else
  run_build
fi

test -s "$OUTPUT_FILE"
test -s "$OUTPUT_FILE.sha256"
(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$OUTPUT_FILE.sha256")")
echo "[OK] Generic x86_64 image: $OUTPUT_FILE"
timing_status=passed
