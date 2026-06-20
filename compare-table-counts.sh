#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: compare-table-counts.sh [--db-both|--db-mssql-only|--db-postgresql-only]

  (no flags)            Full comparison: row counts, keys, foreign keys,
                        indexes, and the RI/index summary, for both SQL
                        Server and PostgreSQL.
  --db-both             Only gather and print per-table row counts for both
                        databases, skip the key/FK/index comparison.
  --db-mssql-only       Only gather and print SQL Server row counts; no
                        PostgreSQL connection is made.
  --db-postgresql-only  Only gather and print PostgreSQL row counts; no
                        SQL Server connection is made.
EOF
}

COUNTS_ONLY=0
SIDE=both
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-both) COUNTS_ONLY=1; SIDE=both; shift ;;
    --db-mssql-only) COUNTS_ONLY=1; SIDE=mssql; shift ;;
    --db-postgresql-only) COUNTS_ONLY=1; SIDE=postgres; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

NEED_MSSQL=1
NEED_PG=1
if [[ "$COUNTS_ONLY" -eq 1 ]]; then
  [[ "$SIDE" == "postgres" ]] && NEED_MSSQL=0
  [[ "$SIDE" == "mssql" ]] && NEED_PG=0
fi

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

if [[ "$NEED_MSSQL" -eq 1 && -z "${MSSQL_PASSWORD:-}" ]]; then
  read -rsp "SQL Server password for ${MSSQL_USER}: " MSSQL_PASSWORD
  echo
fi

if [[ "$NEED_PG" -eq 1 && -z "${PGPASSWORD:-}" ]]; then
  read -rsp "PostgreSQL password for ${PGUSER}: " PGPASSWORD
  echo
  export PGPASSWORD
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mssql_file="$tmpdir/mssql.tsv"
pg_file="$tmpdir/postgres.tsv"
mssql_constraints_file="$tmpdir/mssql_constraints.tsv"
pg_constraints_file="$tmpdir/postgres_constraints.tsv"
mssql_indexes_file="$tmpdir/mssql_indexes.tsv"
pg_indexes_file="$tmpdir/postgres_indexes.tsv"
mssql_summary_file="$tmpdir/mssql_summary.tsv"
pg_summary_file="$tmpdir/postgres_summary.tsv"

compare_catalog_files() {
  local title="$1"
  local left_file="$2"
  local right_file="$3"

  echo
  echo "$title:"
  printf '%*s\n' "${#title}" '' | tr ' ' '-'
  printf "%-120s %-10s\n" "object" "status"

  join -t $'\t' -a 1 -a 2 -e "MISSING" -o '0,1.2,2.2' \
    "$left_file" "$right_file" |
  while IFS=$'\t' read -r object in_mssql in_pg; do
    if [[ "$in_mssql" == "1" && "$in_pg" == "1" ]]; then
      status="OK"
    elif [[ "$in_mssql" == "1" ]]; then
      status="MISSING_IN_POSTGRES"
    else
      status="EXTRA_IN_POSTGRES"
    fi

    printf "%-120s %-10s\n" "$object" "$status"
  done
}

print_summary_comparison() {
  echo
  echo "Schema summary:"
  echo "---------------"
  printf "%-32s %15s %15s %15s %s\n" "metric" "mssql" "postgres" "diff" "status"

  join -t $'\t' -a 1 -a 2 -e "MISSING" -o '0,1.2,2.2' \
    "$mssql_summary_file" "$pg_summary_file" |
  while IFS=$'\t' read -r metric mssql_count pg_count; do
    if [[ "$mssql_count" == "MISSING" || "$pg_count" == "MISSING" ]]; then
      diff="n/a"
      status="MISSING"
    else
      diff=$((pg_count - mssql_count))
      if [[ "$diff" -eq 0 ]]; then
        status="OK"
      else
        status="DIFF"
      fi
    fi

    printf "%-32s %15s %15s %15s %s\n" \
      "$metric" "$mssql_count" "$pg_count" "$diff" "$status"
  done
}

if [[ "$NEED_MSSQL" -eq 1 ]]; then
  echo "Counting SQL Server tables..." >&2

  "$SQLCMD" \
    -S "${MSSQL_HOST},${MSSQL_PORT}" \
    -U "$MSSQL_USER" \
    -P "$MSSQL_PASSWORD" \
    -d "$MSSQL_DB" \
    -C \
    -W \
    -h -1 \
    -s $'\t' \
    -Q "
SET NOCOUNT ON;

DECLARE
    @schema sysname,
    @table sysname,
    @sql nvarchar(max);

IF OBJECT_ID('tempdb..#counts') IS NOT NULL
    DROP TABLE #counts;

CREATE TABLE #counts (
    schema_name sysname,
    table_name sysname,
    row_count bigint
);

DECLARE table_cursor CURSOR FAST_FORWARD FOR
SELECT
    s.name AS schema_name,
    t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @schema, @table;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        INSERT INTO #counts(schema_name, table_name, row_count)
        SELECT
            @schema_name,
            @table_name,
            COUNT_BIG(*)
        FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N';';

    EXEC sp_executesql
        @sql,
        N'@schema_name sysname, @table_name sysname',
        @schema_name = @schema,
        @table_name = @table;

    FETCH NEXT FROM table_cursor INTO @schema, @table;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;

SELECT
    TRANSLATE(CASE WHEN schema_name = 'dbo' THEN 'public' ELSE schema_name END COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') + '.' +
    TRANSLATE(table_name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'),
    row_count
FROM #counts
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort > "$mssql_file"
fi

if [[ "$NEED_PG" -eq 1 ]]; then
  echo "Counting PostgreSQL tables..." >&2

  psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -At \
    -F $'\t' \
    -c "
WITH tables AS (
  SELECT schemaname, tablename
  FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),
counts AS (
  SELECT
    lower(schemaname || '.' || tablename) AS table_key,
    format('%I.%I', schemaname, tablename) AS table_ref
  FROM tables
)
SELECT
  table_key,
  (xpath('/row/c/text()', query_to_xml(
    format('SELECT COUNT(*) AS c FROM %s', table_ref),
    false,
    true,
    ''
  )))[1]::text::bigint AS row_count
FROM counts
ORDER BY table_key;
" | sed '/^[[:space:]]*$/d' | sort > "$pg_file"
fi

if [[ "$NEED_MSSQL" -eq 1 ]]; then
  echo
  echo "MSSQL counts:"
  echo "------------"
  column -t -s $'\t' "$mssql_file"
fi

if [[ "$NEED_PG" -eq 1 ]]; then
  echo
  echo "PostgreSQL counts:"
  echo "------------------"
  column -t -s $'\t' "$pg_file"
fi

if [[ "$COUNTS_ONLY" -eq 1 && "$SIDE" != "both" ]]; then
  exit 0
fi

echo
echo "Comparison:"
echo "-----------"
printf "%-60s %15s %15s %15s %s\n" "table" "mssql" "postgres" "diff" "status"

join -t $'\t' -a 1 -a 2 -e "MISSING" -o '0,1.2,2.2' \
  "$mssql_file" "$pg_file" |
while IFS=$'\t' read -r table mssql_count pg_count; do
  if [[ "$mssql_count" == "MISSING" || "$pg_count" == "MISSING" ]]; then
    diff="n/a"
    status="MISSING"
  else
    diff=$((pg_count - mssql_count))
    if [[ "$diff" -eq 0 ]]; then
      status="OK"
    else
      status="DIFF"
    fi
  fi

  printf "%-60s %15s %15s %15s %s\n" \
    "$table" "$mssql_count" "$pg_count" "$diff" "$status"
done

if [[ "$COUNTS_ONLY" -eq 1 ]]; then
  exit 0
fi

echo "Reading SQL Server keys, foreign keys, indexes, and RI metadata..." >&2

"$SQLCMD" \
  -S "${MSSQL_HOST},${MSSQL_PORT}" \
  -U "$MSSQL_USER" \
  -P "$MSSQL_PASSWORD" \
  -d "$MSSQL_DB" \
  -C \
  -W \
  -h -1 \
  -s $'\t' \
  -Q "
SET NOCOUNT ON;

WITH key_columns AS (
    SELECT
        kc.object_id,
        kc.type,
        TRANSLATE(CASE WHEN s.name = 'dbo' THEN 'public' ELSE s.name END COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS schema_name,
        TRANSLATE(t.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS table_name,
        TRANSLATE(c.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS column_name,
        ic.key_ordinal
    FROM sys.key_constraints kc
    JOIN sys.tables t
        ON t.object_id = kc.parent_object_id
    JOIN sys.schemas s
        ON s.schema_id = t.schema_id
    JOIN sys.index_columns ic
        ON ic.object_id = kc.parent_object_id
       AND ic.index_id = kc.unique_index_id
       AND ic.key_ordinal > 0
    JOIN sys.columns c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE t.is_ms_shipped = 0
      AND kc.type = 'PK'
),
key_objects AS (
    SELECT
        schema_name,
        table_name,
        'primary_key' AS object_type,
        STRING_AGG(column_name, ',') WITHIN GROUP (ORDER BY key_ordinal) AS columns
    FROM key_columns
    GROUP BY object_id, type, schema_name, table_name
),
fk_columns AS (
    SELECT
        fk.object_id,
        TRANSLATE(CASE WHEN ps.name = 'dbo' THEN 'public' ELSE ps.name END COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS parent_schema,
        TRANSLATE(pt.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS parent_table,
        TRANSLATE(pc.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS parent_column,
        TRANSLATE(CASE WHEN rs.name = 'dbo' THEN 'public' ELSE rs.name END COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS ref_schema,
        TRANSLATE(rt.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS ref_table,
        TRANSLATE(rc.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS ref_column,
        fkc.constraint_column_id
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc
        ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables pt
        ON pt.object_id = fk.parent_object_id
    JOIN sys.schemas ps
        ON ps.schema_id = pt.schema_id
    JOIN sys.columns pc
        ON pc.object_id = pt.object_id
       AND pc.column_id = fkc.parent_column_id
    JOIN sys.tables rt
        ON rt.object_id = fk.referenced_object_id
    JOIN sys.schemas rs
        ON rs.schema_id = rt.schema_id
    JOIN sys.columns rc
        ON rc.object_id = rt.object_id
       AND rc.column_id = fkc.referenced_column_id
    WHERE fk.is_ms_shipped = 0
      AND fk.is_disabled = 0
),
fk_objects AS (
    SELECT
        parent_schema AS schema_name,
        parent_table AS table_name,
        'foreign_key' AS object_type,
        STRING_AGG(parent_column, ',') WITHIN GROUP (ORDER BY constraint_column_id) +
        '->' + ref_schema + '.' + ref_table + '(' +
        STRING_AGG(ref_column, ',') WITHIN GROUP (ORDER BY constraint_column_id) + ')' AS columns
    FROM fk_columns
    GROUP BY object_id, parent_schema, parent_table, ref_schema, ref_table
)
SELECT
    object_type + '|' + schema_name + '.' + table_name + '|' + columns,
    1
FROM (
    SELECT * FROM key_objects
    UNION ALL
    SELECT * FROM fk_objects
) objects
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort -u > "$mssql_constraints_file"

"$SQLCMD" \
  -S "${MSSQL_HOST},${MSSQL_PORT}" \
  -U "$MSSQL_USER" \
  -P "$MSSQL_PASSWORD" \
  -d "$MSSQL_DB" \
  -C \
  -W \
  -h -1 \
  -s $'\t' \
  -Q "
SET NOCOUNT ON;

WITH user_indexes AS (
    SELECT
        i.object_id,
        i.index_id,
        TRANSLATE(CASE WHEN s.name = 'dbo' THEN 'public' ELSE s.name END COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS schema_name,
        TRANSLATE(t.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') AS table_name,
        CASE WHEN i.is_unique = 1 THEN 'unique' ELSE 'nonunique' END AS uniqueness
    FROM sys.indexes i
    JOIN sys.tables t
        ON t.object_id = i.object_id
    JOIN sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND i.type > 0
      AND i.is_hypothetical = 0
      AND i.is_primary_key = 0
)
SELECT
    'index|' + schema_name + '.' + table_name + '|' + uniqueness + '|' +
    'key=' + key_columns.columns + '|include=' + COALESCE(include_columns.columns, ''),
    1
FROM user_indexes ui
CROSS APPLY (
    SELECT STRING_AGG(TRANSLATE(c.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), ',')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE ic.object_id = ui.object_id
      AND ic.index_id = ui.index_id
      AND ic.key_ordinal > 0
) key_columns
OUTER APPLY (
    SELECT STRING_AGG(TRANSLATE(c.name COLLATE DATABASE_DEFAULT, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), ',')
        WITHIN GROUP (ORDER BY ic.index_column_id) AS columns
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE ic.object_id = ui.object_id
      AND ic.index_id = ui.index_id
      AND ic.is_included_column = 1
) include_columns
WHERE key_columns.columns IS NOT NULL
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort -u > "$mssql_indexes_file"

"$SQLCMD" \
  -S "${MSSQL_HOST},${MSSQL_PORT}" \
  -U "$MSSQL_USER" \
  -P "$MSSQL_PASSWORD" \
  -d "$MSSQL_DB" \
  -C \
  -W \
  -h -1 \
  -s $'\t' \
  -Q "
SET NOCOUNT ON;

WITH fk_column_counts AS (
    SELECT constraint_object_id, COUNT(*) AS column_count
    FROM sys.foreign_key_columns
    GROUP BY constraint_object_id
),
index_column_counts AS (
    SELECT i.object_id, i.index_id, COUNT(*) AS column_count
    FROM sys.indexes i
    JOIN sys.index_columns ic
        ON ic.object_id = i.object_id
       AND ic.index_id = i.index_id
       AND ic.key_ordinal > 0
    JOIN sys.tables t
        ON t.object_id = i.object_id
    WHERE t.is_ms_shipped = 0
      AND i.type > 0
      AND i.is_hypothetical = 0
      AND i.is_primary_key = 0
    GROUP BY i.object_id, i.index_id
),
index_include_counts AS (
    SELECT i.object_id, i.index_id, COUNT(*) AS column_count
    FROM sys.indexes i
    JOIN sys.index_columns ic
        ON ic.object_id = i.object_id
       AND ic.index_id = i.index_id
       AND ic.is_included_column = 1
    JOIN sys.tables t
        ON t.object_id = i.object_id
    WHERE t.is_ms_shipped = 0
      AND i.type > 0
      AND i.is_hypothetical = 0
      AND i.is_primary_key = 0
    GROUP BY i.object_id, i.index_id
)
SELECT 'foreign_keys', COUNT(*) FROM sys.foreign_keys WHERE is_ms_shipped = 0 AND is_disabled = 0
UNION ALL SELECT 'foreign_keys_disabled', COUNT(*) FROM sys.foreign_keys WHERE is_ms_shipped = 0 AND is_disabled = 1
UNION ALL SELECT 'foreign_keys_not_trusted', COUNT(*) FROM sys.foreign_keys WHERE is_ms_shipped = 0 AND is_not_trusted = 1
UNION ALL SELECT 'foreign_keys_composite', COUNT(*) FROM fk_column_counts WHERE column_count > 1
UNION ALL SELECT 'indexes', COUNT(*) FROM index_column_counts
UNION ALL SELECT 'indexes_composite', COUNT(*) FROM index_column_counts WHERE column_count > 1
UNION ALL SELECT 'indexes_with_includes', COUNT(*) FROM index_include_counts
UNION ALL SELECT 'primary_keys', COUNT(*) FROM sys.key_constraints WHERE type = 'PK'
UNION ALL
SELECT 'primary_keys_composite', COUNT(*)
FROM (
    SELECT kc.object_id
    FROM sys.key_constraints kc
    JOIN sys.index_columns ic
        ON ic.object_id = kc.parent_object_id
       AND ic.index_id = kc.unique_index_id
       AND ic.key_ordinal > 0
    WHERE kc.type = 'PK'
    GROUP BY kc.object_id
    HAVING COUNT(*) > 1
) x
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort > "$mssql_summary_file"

echo "Reading PostgreSQL keys, foreign keys, indexes, and RI metadata..." >&2

psql \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -At \
  -F $'\t' \
  -c "
WITH constraint_columns AS (
  SELECT
    con.oid,
    con.contype,
    n.nspname AS schema_name,
    cls.relname AS table_name,
    array_to_string(ARRAY(
      SELECT lower(att.attname)
      FROM unnest(con.conkey) WITH ORDINALITY AS cols(attnum, ord)
      JOIN pg_attribute att
        ON att.attrelid = con.conrelid
       AND att.attnum = cols.attnum
      ORDER BY cols.ord
    ), ',') AS parent_columns,
    rn.nspname AS ref_schema_name,
    rcls.relname AS ref_table_name,
    CASE WHEN con.contype = 'f' THEN
      array_to_string(ARRAY(
        SELECT lower(att.attname)
        FROM unnest(con.confkey) WITH ORDINALITY AS cols(attnum, ord)
        JOIN pg_attribute att
          ON att.attrelid = con.confrelid
         AND att.attnum = cols.attnum
        ORDER BY cols.ord
      ), ',')
    END AS ref_columns
  FROM pg_constraint con
  JOIN pg_class cls
    ON cls.oid = con.conrelid
  JOIN pg_namespace n
    ON n.oid = cls.relnamespace
  LEFT JOIN pg_class rcls
    ON rcls.oid = con.confrelid
  LEFT JOIN pg_namespace rn
    ON rn.oid = rcls.relnamespace
  WHERE con.contype IN ('p', 'f')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
)
SELECT
  CASE contype WHEN 'p' THEN 'primary_key' ELSE 'foreign_key' END ||
  '|' || lower(schema_name) || '.' || lower(table_name) || '|' ||
  CASE
    WHEN contype = 'f' THEN parent_columns || '->' || lower(ref_schema_name) || '.' || lower(ref_table_name) || '(' || ref_columns || ')'
    ELSE parent_columns
  END,
  1
FROM constraint_columns
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort -u > "$pg_constraints_file"

psql \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -At \
  -F $'\t' \
  -c "
WITH index_columns AS (
  SELECT
    idx.indexrelid,
    n.nspname AS schema_name,
    tbl.relname AS table_name,
    CASE WHEN idx.indisunique THEN 'unique' ELSE 'nonunique' END AS uniqueness,
    array_to_string(ARRAY(
      SELECT lower(att.attname)
      FROM unnest(idx.indkey::int2[]) WITH ORDINALITY AS cols(attnum, ord)
      JOIN pg_attribute att
        ON att.attrelid = idx.indrelid
       AND att.attnum = cols.attnum
      WHERE cols.ord <= idx.indnkeyatts
      ORDER BY cols.ord
    ), ',') AS key_columns,
    array_to_string(ARRAY(
      SELECT lower(att.attname)
      FROM unnest(idx.indkey::int2[]) WITH ORDINALITY AS cols(attnum, ord)
      JOIN pg_attribute att
        ON att.attrelid = idx.indrelid
       AND att.attnum = cols.attnum
      WHERE cols.ord > idx.indnkeyatts
      ORDER BY cols.ord
    ), ',') AS include_columns
  FROM pg_index idx
  JOIN pg_class tbl
    ON tbl.oid = idx.indrelid
  JOIN pg_namespace n
    ON n.oid = tbl.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND NOT idx.indisprimary
)
SELECT
  'index|' || lower(schema_name) || '.' || lower(table_name) || '|' || uniqueness ||
    '|key=' || key_columns || '|include=' || include_columns,
  1
FROM index_columns
WHERE key_columns <> ''
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort -u > "$pg_indexes_file"

psql \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -At \
  -F $'\t' \
  -c "
WITH user_constraints AS (
  SELECT con.*
  FROM pg_constraint con
  JOIN pg_namespace n
    ON n.oid = con.connamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),
user_indexes AS (
  SELECT idx.*
  FROM pg_index idx
  JOIN pg_class tbl
    ON tbl.oid = idx.indrelid
  JOIN pg_namespace n
    ON n.oid = tbl.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND NOT idx.indisprimary
)
SELECT 'foreign_keys', COUNT(*) FROM user_constraints WHERE contype = 'f'
UNION ALL SELECT 'foreign_keys_disabled', 0
UNION ALL SELECT 'foreign_keys_not_trusted', COUNT(*) FROM user_constraints WHERE contype = 'f' AND NOT convalidated
UNION ALL SELECT 'foreign_keys_composite', COUNT(*) FROM user_constraints WHERE contype = 'f' AND cardinality(conkey) > 1
UNION ALL SELECT 'indexes', COUNT(*) FROM user_indexes
UNION ALL SELECT 'indexes_composite', COUNT(*) FROM user_indexes WHERE indnkeyatts > 1
UNION ALL SELECT 'indexes_with_includes', COUNT(*) FROM user_indexes WHERE indnatts > indnkeyatts
UNION ALL SELECT 'primary_keys', COUNT(*) FROM user_constraints WHERE contype = 'p'
UNION ALL SELECT 'primary_keys_composite', COUNT(*) FROM user_constraints WHERE contype = 'p' AND cardinality(conkey) > 1
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | sort > "$pg_summary_file"

print_summary_comparison
compare_catalog_files "Key and foreign-key comparison" "$mssql_constraints_file" "$pg_constraints_file"
compare_catalog_files "Index comparison" "$mssql_indexes_file" "$pg_indexes_file"
