#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_loader.sh
source "${SCRIPT_DIR}/env_loader.sh"
load_env_file

SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"

MSSQL_HOST="${MSSQL_HOST:?Set MSSQL_HOST in .env or export it}"
MSSQL_PORT="${MSSQL_PORT:-1433}"
MSSQL_DB="${MSSQL_DB:-Turista}"
MSSQL_USER="${MSSQL_USER:-pgloader_user}"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-turista}"
PGUSER="${PGUSER:-turista_pgloader}"

OUTPUT_FILE="${1:-postgres-fks.sql}"

if [[ ! -x "$SQLCMD" ]]; then
  if command -v sqlcmd >/dev/null 2>&1; then
    SQLCMD="$(command -v sqlcmd)"
  else
    echo "ERROR: sqlcmd not found. Install mssql-tools18 first." >&2
    exit 1
  fi
fi

if [[ -z "${MSSQL_PASSWORD:-}" ]]; then
  read -rsp "SQL Server password for ${MSSQL_USER}: " MSSQL_PASSWORD
  echo
fi

tmpfile="$(mktemp)"
resolved_tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile" "$resolved_tmpfile"' EXIT

"$SQLCMD" \
  -S "${MSSQL_HOST},${MSSQL_PORT}" \
  -U "$MSSQL_USER" \
  -P "$MSSQL_PASSWORD" \
  -d "$MSSQL_DB" \
  -C \
  -h -1 \
  -w 65535 \
  -Q "
SET NOCOUNT ON;

DECLARE @newline nchar(1) = NCHAR(10);

WITH fk_columns AS (
    SELECT
        fk.object_id AS fk_object_id,
        fk.name COLLATE DATABASE_DEFAULT AS fk_name,
        SCHEMA_NAME(parent_table.schema_id) COLLATE DATABASE_DEFAULT AS parent_schema,
        parent_table.name COLLATE DATABASE_DEFAULT AS parent_table,
        parent_column.name COLLATE DATABASE_DEFAULT AS parent_column,
        SCHEMA_NAME(referenced_table.schema_id) COLLATE DATABASE_DEFAULT AS referenced_schema,
        referenced_table.name COLLATE DATABASE_DEFAULT AS referenced_table,
        referenced_column.name COLLATE DATABASE_DEFAULT AS referenced_column,
        fkc.constraint_column_id,
        fk.update_referential_action_desc COLLATE DATABASE_DEFAULT AS update_referential_action_desc,
        fk.delete_referential_action_desc COLLATE DATABASE_DEFAULT AS delete_referential_action_desc
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc
        ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables parent_table
        ON parent_table.object_id = fk.parent_object_id
    JOIN sys.columns parent_column
        ON parent_column.object_id = parent_table.object_id
       AND parent_column.column_id = fkc.parent_column_id
    JOIN sys.tables referenced_table
        ON referenced_table.object_id = fk.referenced_object_id
    JOIN sys.columns referenced_column
        ON referenced_column.object_id = referenced_table.object_id
       AND referenced_column.column_id = fkc.referenced_column_id
    WHERE fk.is_ms_shipped = 0
      AND fk.is_disabled = 0
),
fk_sql AS (
    SELECT
        c.fk_object_id,
        MIN(c.fk_name) AS fk_name,
        N'\"' + REPLACE(LOWER(CASE WHEN MIN(c.parent_schema) = N'dbo' THEN N'public' ELSE MIN(c.parent_schema) END), N'\"', N'\"\"') + N'\"' AS pg_parent_schema,
        N'\"' + REPLACE(LOWER(MIN(c.parent_table)), N'\"', N'\"\"') + N'\"' AS pg_parent_table,
        N'\"' + REPLACE(LOWER(CASE WHEN MIN(c.referenced_schema) = N'dbo' THEN N'public' ELSE MIN(c.referenced_schema) END), N'\"', N'\"\"') + N'\"' AS pg_referenced_schema,
        N'\"' + REPLACE(LOWER(MIN(c.referenced_table)), N'\"', N'\"\"') + N'\"' AS pg_referenced_table,
        N'\"' + REPLACE(LOWER(MIN(c.fk_name)), N'\"', N'\"\"') + N'\"' AS pg_constraint_name,
        STRING_AGG(N'\"' + REPLACE(LOWER(c.parent_column), N'\"', N'\"\"') + N'\"', N', ')
            WITHIN GROUP (ORDER BY c.constraint_column_id) AS pg_parent_columns,
        STRING_AGG(N'\"' + REPLACE(LOWER(c.referenced_column), N'\"', N'\"\"') + N'\"', N', ')
            WITHIN GROUP (ORDER BY c.constraint_column_id) AS pg_referenced_columns,
        REPLACE(MIN(c.update_referential_action_desc), N'_', N' ') AS update_action,
        REPLACE(MIN(c.delete_referential_action_desc), N'_', N' ') AS delete_action,
        COUNT(*) AS column_count
    FROM fk_columns c
    GROUP BY c.fk_object_id
)
SELECT
    N'-- ' + fk_name + N' (' + CONVERT(nvarchar(10), column_count) + N' column' +
    CASE WHEN column_count = 1 THEN N'' ELSE N's' END + N')' + @newline +
    N'ALTER TABLE ' + pg_parent_schema + N'.' + pg_parent_table +
    N' DROP CONSTRAINT IF EXISTS ' + pg_constraint_name + N';' + @newline +
    N'ALTER TABLE ' + pg_parent_schema + N'.' + pg_parent_table +
    N' ADD CONSTRAINT ' + pg_constraint_name +
    N' FOREIGN KEY (' + pg_parent_columns + N')' +
    N' REFERENCES ' + pg_referenced_schema + N'.' + pg_referenced_table +
    N' (' + pg_referenced_columns + N')' +
    N' ON UPDATE ' + update_action +
    N' ON DELETE ' + delete_action +
    N';' + @newline
FROM fk_sql
ORDER BY fk_name;
" > "$tmpfile"

cp "$tmpfile" "$resolved_tmpfile"

if [[ -n "${PGPASSWORD:-}" ]] && command -v psql >/dev/null 2>&1; then
  if psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -Atq \
    -c "SELECT 1" >/dev/null 2>&1; then
    psql \
      -h "$PGHOST" \
      -p "$PGPORT" \
      -U "$PGUSER" \
      -d "$PGDATABASE" \
      -At \
      -F $'\t' \
      -c "
SELECT
  table_schema,
  lower(table_name) AS generated_table_name,
  table_name AS actual_table_name
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND table_name <> lower(table_name)
ORDER BY table_schema, table_name;
" |
    while IFS=$'\t' read -r schema generated_table actual_table; do
      PG_SCHEMA="$schema" \
      PG_GENERATED_TABLE="$generated_table" \
      PG_ACTUAL_TABLE="$actual_table" \
      perl -0pi -e '
        my $from = "\"" . $ENV{PG_SCHEMA} . "\".\"" . $ENV{PG_GENERATED_TABLE} . "\"";
        my $to = "\"" . $ENV{PG_SCHEMA} . "\".\"" . $ENV{PG_ACTUAL_TABLE} . "\"";
        s/\Q$from\E/$to/g;
      ' "$resolved_tmpfile"
    done
  else
    echo "WARNING: Could not connect to PostgreSQL; generated FK SQL uses SQL Server lower-case identifiers only." >&2
  fi
else
  echo "WARNING: PGPASSWORD not set or psql not found; generated FK SQL uses SQL Server lower-case identifiers only." >&2
fi

{
  echo "-- Generated from SQL Server sys.foreign_keys / sys.foreign_key_columns."
  echo "-- Contains all enabled SQL Server foreign keys, including composite keys."
  echo "-- Run after pgloader has loaded tables, primary keys, and indexes."
  echo "-- pgloader should be configured with 'no foreign keys' before using this file."
  echo "-- Mixed-case PostgreSQL table names are resolved from the target catalog when PGPASSWORD is set."
  echo
  sed '/^[[:space:]]*$/d' "$resolved_tmpfile"
} > "$OUTPUT_FILE"

echo "Wrote $OUTPUT_FILE"
