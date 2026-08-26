#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
OCI_CLI=${OCI_CLI:-/usr/local/bin/oci}
BUCKET=${ORACLE_BUCKET_NAME:-guix-images}
OBJECT=${ORACLE_OBJECT_NAME:-}
DISPLAY_NAME=${ORACLE_IMAGE_DISPLAY_NAME:-${OBJECT%.qcow2}}
NAMESPACE=${ORACLE_NAMESPACE:-}
STATE_DIR="$REPO_ROOT/.oracle-validation/imports"
STATE_FILE="$STATE_DIR/$OBJECT.tsv"

case "$OBJECT" in ''|*[!A-Za-z0-9._-]*) echo "[ERROR] unsafe or missing ORACLE_OBJECT_NAME" >&2; exit 2;; esac
case "$DISPLAY_NAME" in ''|*[!A-Za-z0-9._-]*) echo "[ERROR] unsafe image display name" >&2; exit 2;; esac
mkdir -p "$STATE_DIR"

if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$($OCI_CLI os ns get --query data --raw-output)
fi
compartment=$(awk -F= '/^tenancy=/{print $2; exit}' "$HOME/.oci/config")
test -n "$compartment"

image_id=
if [ -s "$STATE_FILE" ]; then
  IFS=$'\t' read -r recorded_object image_id <"$STATE_FILE"
  [ "$recorded_object" = "$OBJECT" ] || { echo "[ERROR] import state mismatch" >&2; exit 2; }
  echo "[OK] Resuming image import: $image_id"
else
  image_id=$(
    "$OCI_CLI" compute image import from-object \
      --compartment-id "$compartment" --namespace "$NAMESPACE" \
      --bucket-name "$BUCKET" --name "$OBJECT" \
      --display-name "$DISPLAY_NAME" --source-image-type QCOW2 \
      --launch-mode PARAVIRTUALIZED --operating-system 'Guix System' \
      --operating-system-version rolling --query data.id --raw-output
  )
  case "$image_id" in ocid1.image.*) ;; *) echo "[ERROR] import returned no image OCID" >&2; exit 1;; esac
  printf '%s\t%s\n' "$OBJECT" "$image_id" >"$STATE_FILE"
  echo "[OK] Image import started: $image_id"
fi

for attempt in $(seq 1 60); do
  state=$($OCI_CLI compute image get --image-id "$image_id" \
    --query 'data."lifecycle-state"' --raw-output)
  echo "image state: $state"
  case "$state" in
    AVAILABLE) printf '%s\n' "$image_id" >"$STATE_DIR/latest-image-id"; exit 0;;
    IMPORT_ERROR) exit 1;;
  esac
  sleep 20
done
echo "[ERROR] timed out waiting for image import" >&2
exit 124
