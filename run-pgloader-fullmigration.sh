#!/usr/bin/env bash
set -xveuo pipefail

##################################
# load .env / shell configuration
##################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_loader.sh
source "${SCRIPT_DIR}/env_loader.sh"
load_env_file

MSSQL_DB="${MSSQL_DB:-Turista}"
MSSQL_USER="${MSSQL_USER:-pgloader_user}"
MSSQL_FREETDS_ALIAS="${MSSQL_FREETDS_ALIAS:-turista}"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-turista}"
PGUSER="${PGUSER:-turista_pgloader}"

# What to do when check-timezones.sh finds a date/time mismatch between
# SQL Server and PostgreSQL: abort (stop the migration), warn (log and
# continue), or ignore (skip the check entirely). Set TIMEZONE_MISMATCH_ACTION
# in .env to change this without editing the script.
TIMEZONE_MISMATCH_ACTION="${TIMEZONE_MISMATCH_ACTION:-abort}"

if [[ -z "${MSSQL_PASSWORD:-}" ]]; then
  read -rsp "SQL Server password for ${MSSQL_USER}: " MSSQL_PASSWORD
  echo
fi
export MSSQL_PASSWORD

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -rsp "PostgreSQL password for ${PGUSER}: " PGPASSWORD
  echo
fi
export PGPASSWORD

export MSSQL_DB MSSQL_USER MSSQL_FREETDS_ALIAS PGHOST PGPORT PGDATABASE PGUSER

##################################
# run pgloader to migrate data
##################################

export FREETDS=/etc/freetds/freetds.conf
export FREETDSCONF=/etc/freetds/freetds.conf
export TDSVER=7.4
export TDSPORT=1433
export TDS_MAX_CONN=512
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

LOAD_FILE="${SCRIPT_DIR}/mssql-to-postgres.load"
rm -f "$LOAD_FILE"
envsubst '$MSSQL_USER $MSSQL_PASSWORD $MSSQL_DB $MSSQL_HOST $MSSQL_FREETDS_ALIAS $PGUSER $PGPASSWORD $PGHOST $PGPORT $PGDATABASE' \
  < "${SCRIPT_DIR}/mssql-to-postgres.load.template" > "$LOAD_FILE"

LOG_FILE=/root/pgload/pgloader-verbose.log

#/usr/bin/pgloader --verbose mssql-to-postgres.load
#/usr/bin/pgloader mssql-to-postgres.load
#exec /root/pgloader/build/bin/pgloader --verbose mssql-to-postgres.load
/root/pgloader/build/bin/pgloader --verbose "$LOAD_FILE" &> "$LOG_FILE"
#/root/pgloader/build/bin/pgloader --debug mssql-to-postgres.load &> /root/pgload/pgloader-debug.log

##################################
# prepare the composite key / fks
##################################

./generate-postgres-fks.sh postgres-fks.sql &>> "$LOG_FILE"

psql \
  -h "${PGHOST}" \
  -p "${PGPORT}" \
  -U "${PGUSER}" \
  -d "${PGDATABASE}" \
  -v ON_ERROR_STOP=1 \
  -f postgres-fks.sql &>> "$LOG_FILE"


##################################
# check timezone correctness
##################################

if [[ "$TIMEZONE_MISMATCH_ACTION" == "ignore" ]]; then
  echo "Skipping timezone check (TIMEZONE_MISMATCH_ACTION=ignore)." >> "$LOG_FILE"
else
  set +e
  ./check-timezones.sh &>> "$LOG_FILE"
  timezone_check_status=$?
  set -e

  if [[ "$timezone_check_status" -ne 0 ]]; then
    case "$TIMEZONE_MISMATCH_ACTION" in
      abort)
        echo "Timezone check found a mismatch between SQL Server and PostgreSQL." >&2
        echo "See $LOG_FILE for details. Aborting (TIMEZONE_MISMATCH_ACTION=abort)." >&2
        echo "Set TIMEZONE_MISMATCH_ACTION=warn or =ignore in .env to change this." >&2
        exit 1
        ;;
      warn)
        echo "WARNING: timezone check found a mismatch between SQL Server and" >&2
        echo "PostgreSQL. See $LOG_FILE for details. Continuing anyway" >&2
        echo "(TIMEZONE_MISMATCH_ACTION=warn)." >&2
        ;;
      *)
        echo "Unknown TIMEZONE_MISMATCH_ACTION='${TIMEZONE_MISMATCH_ACTION}'" >&2
        echo "(expected abort, warn, or ignore). Aborting." >&2
        exit 1
        ;;
    esac
  fi
fi

##################################
# finally compare
##################################
./compare-table-counts.sh

echo "Read evtl. issues during processing in $LOG_FILE"
