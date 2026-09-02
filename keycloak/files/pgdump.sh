#!/bin/sh
# ---------------------------------------------------------------------------
# kc-pgdump initContainer (postgres:17-alpine): logical dump of the Keycloak
# database into the shared /backup emptyDir. upload.sh (next container) ships
# whatever it finds there.
#
# Connection comes entirely from PG* env, which the keycloak-db Secret carries
# alongside the KC_DB_* values so the dump can never drift from what Keycloak
# itself connects to. PREFIX comes from the keycloak-backup-s3 Secret.
#
# --compress uses pg_dump's built-in zlib so there is no shell pipeline (and
# therefore no pipefail dependency) between pg_dump and the file on disk.
# --no-owner/--no-privileges because the restore target is a managed cluster
# whose admin role is not the role that owns the objects here.
# ---------------------------------------------------------------------------
set -eu

: "${PGHOST:?PGHOST missing from keycloak-db secret}"
: "${PGDATABASE:?PGDATABASE missing from keycloak-db secret}"
: "${PGUSER:?PGUSER missing from keycloak-db secret}"
: "${PGPASSWORD:?PGPASSWORD missing from keycloak-db secret}"
: "${PREFIX:?PREFIX missing from keycloak-backup-s3 secret}"
export PGPORT="${PGPORT:-5432}"
export PGSSLMODE="${PGSSLMODE:-require}"

# libpq reads PGSSLROOTCERT itself; the checks here only turn "no such file"
# / a silent fallback to ~/.postgresql/root.crt into a clear Job failure
# before any dump is attempted. The CA is mounted from the keycloak-db Secret
# when the module pins one.
if [ -n "${PGSSLROOTCERT:-}" ]; then
  [ -r "${PGSSLROOTCERT}" ] || { echo "PGSSLROOTCERT=${PGSSLROOTCERT} is not readable" >&2; exit 1; }
  export PGSSLROOTCERT
fi
case "${PGSSLMODE}" in
  verify-ca|verify-full)
    [ -n "${PGSSLROOTCERT:-}" ] || { echo "PGSSLMODE=${PGSSLMODE} needs PGSSLROOTCERT" >&2; exit 1; } ;;
esac

BACKUP_DIR="${BACKUP_DIR:-/backup}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${BACKUP_DIR}/${PREFIX}-pgdump-${STAMP}.sql.gz"

echo "pg_dump ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE} (sslmode=${PGSSLMODE}${PGSSLROOTCERT:+ sslrootcert=${PGSSLROOTCERT}}) -> ${OUT}"
pg_dump --format=plain --no-owner --no-privileges --compress=gzip:6 --file="${OUT}"

# An empty or truncated dump must fail the Job rather than be uploaded as if
# it were a backup.
[ -s "${OUT}" ] || { echo "dump file is empty" >&2; exit 1; }
gzip -t "${OUT}"
ls -l "${OUT}"
