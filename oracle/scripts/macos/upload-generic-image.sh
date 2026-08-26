#!/usr/bin/env bash
set -euo pipefail

# Upload a generic QCOW2 with OCI's multipart integrity verification enabled,
# then independently compare the remote composite MD5 and byte count.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
OCI_CLI=${OCI_CLI:-/usr/local/bin/oci}
IMAGE_FILE=${ORACLE_IMAGE_FILE:-$REPO_ROOT/.oracle-validation/builds/ov2-current/guix-oracle-generic.qcow2}
BUCKET=${ORACLE_BUCKET_NAME:-guix-images}
OBJECT=${ORACLE_OBJECT_NAME:-}
PART_MIB=${ORACLE_UPLOAD_PART_MIB:-128}
TIMING_FILE="$REPO_ROOT/.oracle-validation/timings.tsv"
timing_started=$(date +%s)
timing_status=failed
timing_prediction=$(
  awk -F '\t' '$2 == "image-upload" && ($3 == "passed" || $3 == "failed") { print $4 }' \
    "$TIMING_FILE" 2>/dev/null | sort -n | awk '{ value[NR]=$1 } END { if (NR) print value[int((NR+1)/2)] }'
)
if [ -n "$timing_prediction" ]; then
  echo "[TIME] image-upload predicted: ${timing_prediction}s (historical median)"
else
  echo "[TIME] image-upload predicted: insufficient history"
fi
record_timing() {
  timing_ended=$(date +%s)
  timing_actual=$((timing_ended - timing_started))
  mkdir -p "$(dirname "$TIMING_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" image-upload "$timing_status" \
    "$timing_actual" "$OBJECT" >>"$TIMING_FILE"
  if [ -n "$timing_prediction" ]; then
    echo "[TIME] image-upload actual: ${timing_actual}s; delta from median: $((timing_actual - timing_prediction))s"
  else
    echo "[TIME] image-upload actual: ${timing_actual}s; first sample recorded"
  fi
}
trap record_timing EXIT

if [ -z "$OBJECT" ]; then
  echo "[ERROR] ORACLE_OBJECT_NAME is required" >&2
  exit 2
fi
case "$OBJECT" in
  *[!A-Za-z0-9._-]*)
    echo "[ERROR] ORACLE_OBJECT_NAME contains unsafe characters" >&2
    exit 2
    ;;
esac
test -s "$IMAGE_FILE"

local_size=$(stat -f %z "$IMAGE_FILE" 2>/dev/null || true)
case "$local_size" in
  ''|*[!0-9]*) local_size=$(stat -c %s "$IMAGE_FILE") ;;
esac

remote_size=$(
  "$OCI_CLI" os object head --bucket-name "$BUCKET" --name "$OBJECT" \
    --query '"content-length"' --raw-output 2>/dev/null || true
)
if [ "$remote_size" != "$local_size" ]; then
  "$OCI_CLI" os object put --bucket-name "$BUCKET" --name "$OBJECT" \
    --file "$IMAGE_FILE" --part-size "$PART_MIB" \
    --parallel-upload-count 4 --no-overwrite --verify-checksum \
    --opc-checksum-algorithm SHA256
fi

remote_size=$(
  "$OCI_CLI" os object head --bucket-name "$BUCKET" --name "$OBJECT" \
    --query '"content-length"' --raw-output
)
remote_md5=$(
  "$OCI_CLI" os object head --bucket-name "$BUCKET" --name "$OBJECT" \
    --query '"opc-multipart-md5"' --raw-output
)
local_md5=$(python3 -c '
import base64, hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
part_bytes = int(sys.argv[2]) * 1024 * 1024
digests = []
with path.open("rb") as stream:
    while chunk := stream.read(part_bytes):
        digests.append(hashlib.md5(chunk).digest())
print(base64.b64encode(hashlib.md5(b"".join(digests)).digest()).decode()
      + "-" + str(len(digests)))
' "$IMAGE_FILE" "$PART_MIB")

if [ "$remote_size" != "$local_size" ]; then
  echo "[ERROR] remote size $remote_size != local size $local_size" >&2
  exit 1
fi
if [ "$remote_md5" != "$local_md5" ]; then
  echo "[ERROR] remote multipart MD5 does not match local file" >&2
  exit 1
fi

echo "[OK] OCI multipart object verified"
echo "  bucket: $BUCKET"
echo "  object: $OBJECT"
echo "  bytes:  $local_size"
echo "  md5:    $local_md5"
timing_status=passed
