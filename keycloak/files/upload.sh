#!/bin/sh
# ---------------------------------------------------------------------------
# Backup uploader (amazon/aws-cli image), shared by the kc-pgdump and
# kc-realm-export CronJobs.
#
#   1. make sure the bucket exists (Vultr object storage only provisions the
#      subscription; buckets are created through the S3 API),
#   2. pack a realm-export directory into a .tgz if the initContainer left one,
#   3. upload every regular file in /backup to s3://BUCKET/PREFIX/BACKUP_KIND/,
#   4. prune objects under that same key prefix older than RETENTION_DAYS.
#
# Env (from the keycloak-backup-s3 Secret + CronJob spec):
#   AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_ENDPOINT BUCKET PREFIX
#   BACKUP_KIND (pgdump | realm-export)  RETENTION_DAYS
#
# The aws-cli image is Amazon Linux 2023: it has python3 and GNU date but NO
# tar or gzip, hence python's tarfile module for packing and `date -d` for the
# retention comparison. Nothing here relies on busybox.
# ---------------------------------------------------------------------------
set -eu

: "${S3_ENDPOINT:?S3_ENDPOINT missing}"
: "${BUCKET:?BUCKET missing}"
: "${PREFIX:?PREFIX missing}"
: "${BACKUP_KIND:?BACKUP_KIND missing}"
: "${RETENTION_DAYS:?RETENTION_DAYS missing}"

BACKUP_DIR="${BACKUP_DIR:-/backup}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Trailing slash matters: it keeps the prune listing inside our own "folder"
# and stops PREFIX=foo from ever matching foo-other/.
KEY_PREFIX="${PREFIX}/${BACKUP_KIND}/"

s3() { aws --endpoint-url "${S3_ENDPOINT}" "$@"; }

# --- 1. bucket ---------------------------------------------------------------
if ! s3 s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "bucket ${BUCKET} not found at ${S3_ENDPOINT}; creating it"
  s3 s3api create-bucket --bucket "${BUCKET}" >/dev/null
fi

# --- 2. directory artefact (realm export) ------------------------------------
# amazon/aws-cli has no tar and its python is 2.7 (no tarfile CLI — the first
# staging run "packed" nothing and exited 0), so the realm export is uploaded
# as-is: one object per file under a timestamped folder. Restore = download the
# folder and `kc.sh import --dir` it; nothing to unpack.
uploaded=0
if [ -d "${BACKUP_DIR}/realms" ]; then
  n="$(find "${BACKUP_DIR}/realms" -type f | wc -l)"
  [ "${n}" -gt 0 ] || { echo "realm export produced no files in ${BACKUP_DIR}/realms" >&2; exit 1; }
  dest="s3://${BUCKET}/${KEY_PREFIX}${PREFIX}-realms-${STAMP}/"
  echo "upload ${BACKUP_DIR}/realms/ (${n} files) -> ${dest}"
  s3 s3 cp --only-show-errors --recursive "${BACKUP_DIR}/realms/" "${dest}"
  uploaded=$((uploaded + n))
  rm -rf "${BACKUP_DIR}/realms"
fi

# --- 3. upload ---------------------------------------------------------------
for f in "${BACKUP_DIR}"/*; do
  [ -f "${f}" ] || continue
  [ -s "${f}" ] || { echo "refusing to upload empty file ${f}" >&2; exit 1; }
  key="${KEY_PREFIX}$(basename "${f}")"
  echo "upload ${f} -> s3://${BUCKET}/${key}"
  s3 s3 cp --only-show-errors "${f}" "s3://${BUCKET}/${key}"
  uploaded=$((uploaded + 1))
done
if [ "${uploaded}" -eq 0 ]; then
  echo "nothing to upload in ${BACKUP_DIR} - the initContainer produced no artefact" >&2
  exit 1
fi

# --- 4. prune ----------------------------------------------------------------
# Only ever within KEY_PREFIX, only when retention is a positive number, and
# an unparseable LastModified skips the object rather than deleting it.
case "${RETENTION_DAYS}" in
  ''|*[!0-9]*) echo "RETENTION_DAYS=${RETENTION_DAYS} is not a number; skipping prune" >&2; exit 0 ;;
esac
if [ "${RETENTION_DAYS}" -lt 1 ]; then
  echo "RETENTION_DAYS=${RETENTION_DAYS}; prune disabled"
  exit 0
fi

cutoff="$(date -u -d "-${RETENTION_DAYS} days" +%s)"
listing="$(mktemp)"
s3 s3api list-objects-v2 --bucket "${BUCKET}" --prefix "${KEY_PREFIX}" \
  --query 'Contents[].[Key,LastModified]' --output text > "${listing}"

pruned=0
tab="$(printf '\t')"
while IFS="${tab}" read -r key lastmod; do
  # An empty prefix lists as the single word "None".
  [ -n "${lastmod}" ] || continue
  ts="$(date -u -d "${lastmod}" +%s 2>/dev/null)" || {
    echo "skip ${key}: cannot parse LastModified '${lastmod}'" >&2
    continue
  }
  if [ "${ts}" -lt "${cutoff}" ]; then
    echo "prune ${key} (${lastmod})"
    s3 s3api delete-object --bucket "${BUCKET}" --key "${key}" >/dev/null
    pruned=$((pruned + 1))
  fi
done < "${listing}"
rm -f "${listing}"

echo "done: uploaded=${uploaded} pruned=${pruned} retention=${RETENTION_DAYS}d prefix=s3://${BUCKET}/${KEY_PREFIX}"
