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

# Accented Latin letters used by German (DE/AT), Swiss German/French/Italian
# (CH), and Dutch (NL) text: umlauts, sharp s, and the wider set of French/
# Dutch/Italian diacritics that show up in the same address/name fields.
SPECIAL_CHARS='ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝŸŒßẞàáâãäåæçèéêëìíîïñòóôõöøùúûüýÿœ'

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
export MSSQL_PASSWORD

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -rsp "PostgreSQL password for ${PGUSER}: " PGPASSWORD
  echo
fi
export PGPASSWORD

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_sqlcmd() {
  "$SQLCMD" \
    -S "${MSSQL_HOST},${MSSQL_PORT}" \
    -U "$MSSQL_USER" \
    -P "$MSSQL_PASSWORD" \
    -d "$MSSQL_DB" \
    -C \
    -W \
    -h -1 \
    -s $'\t' \
    -Q "$1"
}

run_sqlcmd_wide() {
  # -y/-W are mutually exclusive in sqlcmd, and -W (used by run_sqlcmd) caps
  # the display width of varchar(max)/nvarchar(max) output to 256 chars,
  # silently truncating long memo fields. -y 8000 lifts that cap, but then
  # sqlcmd right-pads every "(max)" column out to the full 8000 chars with
  # spaces, so the SQL must append a non-space end-of-value marker (CHAR(1))
  # that callers strip the padding after.
  "$SQLCMD" \
    -S "${MSSQL_HOST},${MSSQL_PORT}" \
    -U "$MSSQL_USER" \
    -P "$MSSQL_PASSWORD" \
    -d "$MSSQL_DB" \
    -C \
    -y 8000 \
    -h -1 \
    -Q "$1"
}

run_psql() {
  psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -At \
    -F $'\t' \
    -c "$1"
}

section() {
  echo
  echo "$1"
  printf '%*s\n' "${#1}" '' | tr ' ' '='
}

mssql_ok=1
pg_ok=1
mismatches=0
total=0

##################################
# 1. Encoding / collation context
##################################

section "1. Encoding and collation context"

if mssql_collation="$(run_sqlcmd "
SET NOCOUNT ON;
SELECT 'server_collation', CONVERT(varchar(100), SERVERPROPERTY('Collation'))
UNION ALL SELECT 'database_collation', CONVERT(varchar(100), DATABASEPROPERTYEX(DB_NAME(), 'Collation'))
UNION ALL SELECT 'product_version', CONVERT(varchar(50), SERVERPROPERTY('ProductVersion'));
" 2>&1)"; then
  echo "$mssql_collation" | sed '/^[[:space:]]*$/d' | column -t -s $'\t'
else
  echo "WARNING: could not query SQL Server collation:" >&2
  echo "$mssql_collation" >&2
  mssql_ok=0
fi

freetds_charset="$(grep -iE 'client charset' /etc/freetds/freetds.conf 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')"
echo "freetds_client_charset	${freetds_charset:-not set / file not found}" | column -t -s $'\t'

if pg_encoding="$(run_psql "
SELECT 'server_encoding', current_setting('server_encoding')
UNION ALL SELECT 'client_encoding', current_setting('client_encoding')
UNION ALL SELECT 'lc_collate', current_setting('lc_collate');
" 2>&1)"; then
  echo "$pg_encoding" | sed '/^[[:space:]]*$/d' | column -t -s $'\t'
else
  echo "WARNING: could not query PostgreSQL encoding settings:" >&2
  echo "$pg_encoding" >&2
  pg_ok=0
fi

##################################
# 2. Per-column census (row counts)
##################################

section "2. Columns containing German/NL/CH/AT accented characters (row counts)"

mssql_census_file="$tmpdir/mssql_census.tsv"
pg_census_file="$tmpdir/pg_census.tsv"

if [[ "$mssql_ok" == "1" ]]; then
  echo "Reading SQL Server column census..." >&2
  if ! run_sqlcmd "
SET NOCOUNT ON;

DECLARE
    @schema sysname, @table sysname, @column sysname,
    @sql nvarchar(max), @table_key nvarchar(264);

IF OBJECT_ID('tempdb..#census') IS NOT NULL
    DROP TABLE #census;

CREATE TABLE #census (
    table_key nvarchar(264),
    column_name sysname,
    cnt bigint
);

DECLARE col_cursor CURSOR FAST_FORWARD FOR
SELECT s.name, t.name, c.name
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN ('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext')
ORDER BY s.name, t.name, c.name;

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @schema, @table, @column;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @table_key = (CASE WHEN @schema = 'dbo' THEN 'public' ELSE @schema END) + N'.' + @table;

    SET @sql = N'
        INSERT INTO #census(table_key, column_name, cnt)
        SELECT @table_key, @column_name, COUNT(*)
        FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N'
        WHERE CAST(' + QUOTENAME(@column) + N' AS nvarchar(max)) COLLATE Latin1_General_100_CS_AS_SC LIKE N''%[$SPECIAL_CHARS]%'';';

    EXEC sp_executesql
        @sql,
        N'@table_key nvarchar(264), @column_name sysname',
        @table_key = @table_key,
        @column_name = @column;

    FETCH NEXT FROM col_cursor INTO @schema, @table, @column;
END

CLOSE col_cursor;
DEALLOCATE col_cursor;

SELECT
    LOWER(table_key COLLATE DATABASE_DEFAULT) + ':' + LOWER(column_name COLLATE DATABASE_DEFAULT),
    CAST(cnt AS varchar(20))
FROM #census
WHERE cnt > 0
ORDER BY 1;
" 2>"$tmpdir/mssql_census.err" | sed '/^[[:space:]]*$/d' | awk -F'\t' 'NF == 2' | sort > "$mssql_census_file"; then
    echo "WARNING: could not run SQL Server special-character census:" >&2
    cat "$tmpdir/mssql_census.err" >&2
    mssql_ok=0
  fi
fi

if [[ "$pg_ok" == "1" ]]; then
  echo "Reading PostgreSQL column census..." >&2

  pg_census_sql="$(run_psql "
WITH cols AS (
  SELECT table_schema, table_name, column_name
  FROM information_schema.columns
  WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    AND data_type IN ('character varying', 'character', 'text')
)
SELECT string_agg(
  format(
    'SELECT %L AS key, COUNT(*)::text AS cnt FROM %I.%I WHERE %I ~ %L',
    lower(table_schema) || '.' || lower(table_name) || ':' || lower(column_name),
    table_schema, table_name, column_name,
    '[$SPECIAL_CHARS]'
  ),
  E'\nUNION ALL\n'
)
FROM cols;
")"

  if [[ -z "$pg_census_sql" ]]; then
    : > "$pg_census_file"
  else
    pg_census_query_file="$tmpdir/pg_census_query.sql"
    printf '%s\nORDER BY 1;\n' "$pg_census_sql" > "$pg_census_query_file"
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -At -F $'\t' -f "$pg_census_query_file" \
      2>"$tmpdir/pg_census.err" | sed '/^[[:space:]]*$/d' | awk -F'\t' 'NF == 2 && $2 != "0"' | sort > "$pg_census_file"; then
      echo "WARNING: could not run PostgreSQL special-character census:" >&2
      cat "$tmpdir/pg_census.err" >&2
      pg_ok=0
    fi
  fi
fi

if [[ "$mssql_ok" != "1" || "$pg_ok" != "1" ]]; then
  echo "Skipped: needs both SQL Server and PostgreSQL reachable (see warnings above)."
else
  printf "%-60s %15s %15s %s\n" "table.column" "mssql_rows" "postgres_rows" "status"

  census_mismatches=0
  census_total=0

  while IFS=$'\t' read -r key mcnt pcnt; do
    census_total=$((census_total + 1))
    if [[ "$mcnt" == "MISSING" || "$pcnt" == "MISSING" ]]; then
      status="MISSING_IN_$([[ "$mcnt" == "MISSING" ]] && echo MSSQL || echo POSTGRES)"
    elif [[ "$mcnt" != "$pcnt" ]]; then
      status="COUNT_MISMATCH"
    else
      status="OK"
    fi
    [[ "$status" != "OK" ]] && census_mismatches=$((census_mismatches + 1))

    printf "%-60s %15s %15s %s\n" "$key" "$mcnt" "$pcnt" "$status"
  done < <(join -t $'\t' -a 1 -a 2 -e MISSING -o '0,1.2,2.2' "$mssql_census_file" "$pg_census_file")

  echo
  if [[ "$census_total" -eq 0 ]]; then
    echo "No columns with German/NL/CH/AT accented characters found on either side."
  elif [[ "$census_mismatches" -eq 0 ]]; then
    echo "Row-count census: PASS - all $census_total column(s) have matching counts."
  else
    echo "Row-count census: FAIL - $census_mismatches of $census_total column(s) differ. See statuses above."
    mismatches=$((mismatches + census_mismatches))
  fi
  total=$((total + census_total))
fi

candidate_keys_file="$tmpdir/candidate_keys.tsv"
cut -f1 "$mssql_census_file" "$pg_census_file" 2>/dev/null | sort -u > "$candidate_keys_file"

##################################
# 3. Per-value content comparison
##################################

section "3. Accented value content comparison (mojibake / corruption check, up to 200 rows/column)"

if [[ "$mssql_ok" != "1" || "$pg_ok" != "1" ]]; then
  echo "Skipped: needs both SQL Server and PostgreSQL reachable (see warnings above)."
else
  mssql_vals_file="$tmpdir/mssql_vals.tsv"
  pg_vals_file="$tmpdir/pg_vals.tsv"

  echo "Reading SQL Server accented values..." >&2

  run_sqlcmd_wide "
SET NOCOUNT ON;

DECLARE
    @schema sysname, @table sysname, @column sysname,
    @sql nvarchar(max), @table_key nvarchar(264);

IF OBJECT_ID('tempdb..#vals') IS NOT NULL
    DROP TABLE #vals;

CREATE TABLE #vals (
    table_key nvarchar(264),
    column_name sysname,
    value_text nvarchar(max)
);

DECLARE col_cursor CURSOR FAST_FORWARD FOR
SELECT s.name, t.name, c.name
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN ('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext')
ORDER BY s.name, t.name, c.name;

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @schema, @table, @column;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @table_key = (CASE WHEN @schema = 'dbo' THEN 'public' ELSE @schema END) + N'.' + @table;

    SET @sql = N'
        INSERT INTO #vals(table_key, column_name, value_text)
        SELECT TOP (200) @table_key, @column_name,
            REPLACE(REPLACE(REPLACE(CAST(' + QUOTENAME(@column) + N' AS nvarchar(max)), CHAR(13), N''''), CHAR(10), N'' ''), CHAR(9), N'' '')
        FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N'
        WHERE CAST(' + QUOTENAME(@column) + N' AS nvarchar(max)) COLLATE Latin1_General_100_CS_AS_SC LIKE N''%[$SPECIAL_CHARS]%''
        ORDER BY CAST(' + QUOTENAME(@column) + N' AS nvarchar(max)) COLLATE Latin1_General_100_BIN2;';

    EXEC sp_executesql
        @sql,
        N'@table_key nvarchar(264), @column_name sysname',
        @table_key = @table_key,
        @column_name = @column;

    FETCH NEXT FROM col_cursor INTO @schema, @table, @column;
END

CLOSE col_cursor;
DEALLOCATE col_cursor;

SELECT
    LOWER(table_key COLLATE DATABASE_DEFAULT) + ':' + LOWER(column_name COLLATE DATABASE_DEFAULT) + ':' +
    CAST(ROW_NUMBER() OVER (PARTITION BY table_key, column_name ORDER BY value_text COLLATE Latin1_General_100_BIN2) AS varchar(20)) +
    CHAR(9) + value_text + CHAR(1)
FROM #vals
ORDER BY 1;
" | awk -F$'\x01' '{print $1}' | sed '/^[[:space:]]*$/d' | awk -F'\t' 'NF == 2' | sort -t $'\t' -k1,1 > "$mssql_vals_file"

  echo "Reading PostgreSQL accented values..." >&2

  # One UNION ALL across every text column (~275 branches) made PostgreSQL
  # spin up a parallel worker per branch and OOM-killed the whole cluster on
  # this memory-constrained host, even with the per-column LIMIT in place
  # (see memory: pg14-oom-incident). Query one column at a time instead,
  # mirroring the SQL Server side's cursor loop.
  pg_cols_file="$tmpdir/pg_cols.tsv"
  run_psql "
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND data_type IN ('character varying', 'character', 'text')
ORDER BY table_schema, table_name, column_name;
" | sed '/^[[:space:]]*$/d' | \
    awk -F'\t' -v keys="$candidate_keys_file" '
      BEGIN { while ((getline line < keys) > 0) candidate[line] = 1 }
      { key = tolower($1) "." tolower($2) ":" tolower($3); if (key in candidate) print }
    ' > "$pg_cols_file"

  : > "$pg_vals_file"
  while IFS=$'\t' read -r p_schema p_table p_column; do
    [[ -z "$p_schema" ]] && continue
    qschema="${p_schema//\"/\"\"}"
    qtable="${p_table//\"/\"\"}"
    qcolumn="${p_column//\"/\"\"}"
    key_prefix="$(printf '%s' "${p_schema,,}.${p_table,,}:${p_column,,}")"

    PGOPTIONS='-c max_parallel_workers_per_gather=0' \
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -At -F $'\t' -c "
SELECT replace(replace(replace(\"$qcolumn\"::text, chr(13), ''), chr(10), ' '), chr(9), ' ')
FROM \"$qschema\".\"$qtable\"
WHERE \"$qcolumn\" ~ '[$SPECIAL_CHARS]'
ORDER BY \"$qcolumn\" COLLATE \"C\"
LIMIT 200;
" 2>>"$tmpdir/pg_vals.err" | awk -v prefix="$key_prefix" -F'\t' '{print prefix ":" ++n "\t" $0}' >> "$pg_vals_file"
  done < "$pg_cols_file"

  sort -t $'\t' -k1,1 -o "$pg_vals_file" "$pg_vals_file"

  printf "%-70s %-30s %-30s %s\n" "table.column:rank" "mssql_value" "postgres_value" "status"

  value_mismatches=0
  value_total=0

  while IFS=$'\t' read -r key mval pval; do
    value_total=$((value_total + 1))
    if [[ "$mval" == "MISSING" || "$pval" == "MISSING" ]]; then
      status="MISSING_IN_$([[ "$mval" == "MISSING" ]] && echo MSSQL || echo POSTGRES)"
    elif [[ "$mval" != "$pval" ]]; then
      status="MOJIBAKE_OR_MISMATCH"
    else
      status="OK"
    fi
    [[ "$status" != "OK" ]] && value_mismatches=$((value_mismatches + 1))

    printf "%-70s %-30s %-30s %s\n" "$key" "$mval" "$pval" "$status"
  done < <(join -t $'\t' -a 1 -a 2 -e MISSING -o '0,1.2,2.2' "$mssql_vals_file" "$pg_vals_file")

  echo
  if [[ "$value_total" -eq 0 ]]; then
    echo "No accented values found on either side; nothing to compare."
  elif [[ "$value_mismatches" -eq 0 ]]; then
    echo "Value content: PASS - all $value_total accented value(s) match byte-for-byte."
  else
    echo "Value content: FAIL - $value_mismatches of $value_total accented value(s) do not match."
    echo "A mismatch here means the actual character content changed during migration"
    echo "(e.g. mojibake from a charset mismatch, dropped/replaced characters), not just"
    echo "a row-count difference."
    mismatches=$((mismatches + value_mismatches))
  fi
  total=$((total + value_total))
fi

echo
if [[ "$total" -eq 0 ]]; then
  echo "VERDICT: no accented characters found to verify."
elif [[ "$mismatches" -eq 0 ]]; then
  echo "VERDICT: PASS - German/NL/CH/AT accented characters match between SQL Server and PostgreSQL."
else
  echo "VERDICT: FAIL - $mismatches mismatch(es) found. See sections above."
fi

if [[ "$mismatches" -gt 0 ]]; then
  exit 1
fi
exit 0
