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
# 1. MSSQL server / OS timezone
##################################

section "1. SQL Server host clock and timezone"

if mssql_clock="$(run_sqlcmd "
SET NOCOUNT ON;
DECLARE @utc datetime2(3) = SYSUTCDATETIME();
DECLARE @local datetime2(3) = SYSDATETIME();
SELECT 'utc_now', FORMAT(@utc, 'yyyy-MM-dd HH:mm:ss.fff')
UNION ALL SELECT 'local_now', FORMAT(@local, 'yyyy-MM-dd HH:mm:ss.fff')
UNION ALL SELECT 'utc_offset_minutes', CAST(DATEDIFF(MINUTE, @utc, @local) AS varchar(10))
UNION ALL SELECT 'product_version', CAST(SERVERPROPERTY('ProductVersion') AS varchar(50));
" 2>&1)"; then
  echo "$mssql_clock" | sed '/^[[:space:]]*$/d' | column -t -s $'\t'
else
  echo "WARNING: could not query SQL Server clock/version:" >&2
  echo "$mssql_clock" >&2
  mssql_ok=0
fi

if [[ "$mssql_ok" == "1" ]]; then
  if mssql_tz="$(run_sqlcmd "SET NOCOUNT ON; SELECT CURRENT_TIMEZONE();" 2>&1)"; then
    echo "current_timezone (named)	$(echo "$mssql_tz" | sed '/^[[:space:]]*$/d')"
  else
    echo "current_timezone (named)	unavailable (CURRENT_TIMEZONE() requires SQL Server 2022+; using utc_offset_minutes above instead)"
  fi | column -t -s $'\t'
fi

##################################
# 2. MSSQL date/time column census
##################################

section "2. SQL Server date/time/datetimeoffset column census"

if [[ "$mssql_ok" == "1" ]]; then
  if mssql_census="$(run_sqlcmd "
SET NOCOUNT ON;
SELECT
    ty.name,
    CAST(COUNT(*) AS varchar(10)),
    CAST(COUNT(DISTINCT t.object_id) AS varchar(10))
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN ('date', 'time', 'smalldatetime', 'datetime', 'datetime2', 'datetimeoffset')
GROUP BY ty.name
ORDER BY ty.name;
" 2>&1)"; then
    if [[ -z "$(echo "$mssql_census" | tr -d '[:space:]')" ]]; then
      echo "No date/time columns found in user tables."
    else
      printf "data_type\tcolumns\ttables\n%s\n" "$mssql_census" | column -t -s $'\t'
      echo
      echo "Only 'datetimeoffset' stores an explicit UTC offset per row. 'date', 'time',"
      echo "'smalldatetime', 'datetime', and 'datetime2' are naive: no timezone is stored,"
      echo "so the migrated value must remain the same wall-clock text, not be shifted."
    fi
  else
    echo "WARNING: could not query SQL Server column census:" >&2
    echo "$mssql_census" >&2
    mssql_ok=0
  fi
fi

##################################
# 3. PostgreSQL host / session timezone
##################################

section "3. PostgreSQL host and session timezone"

os_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ -z "$os_tz" ]]; then
  os_tz="$(cat /etc/timezone 2>/dev/null || true)"
fi
if [[ -z "$os_tz" ]]; then
  os_tz="$(date +%Z' (UTC%:z)' 2>/dev/null || true)"
fi
echo "host_os_timezone	${os_tz:-unknown}" | column -t -s $'\t'

if pg_tz="$(run_psql "
SELECT 'session_timezone', current_setting('TimeZone')
UNION ALL SELECT 'log_timezone', current_setting('log_timezone')
UNION ALL SELECT 'server_now', to_char(now(), 'YYYY-MM-DD HH24:MI:SS.MS TZ');
" 2>&1)"; then
  echo "$pg_tz" | sed '/^[[:space:]]*$/d' | column -t -s $'\t'
else
  echo "WARNING: could not query PostgreSQL timezone settings:" >&2
  echo "$pg_tz" >&2
  pg_ok=0
fi

##################################
# 4. PostgreSQL date/time column census
##################################

section "4. PostgreSQL date/time/timestamp column census"

if [[ "$pg_ok" == "1" ]]; then
  if pg_census="$(run_psql "
SELECT data_type, COUNT(*), COUNT(DISTINCT table_schema || '.' || table_name)
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND data_type IN ('date', 'time without time zone', 'time with time zone',
                     'timestamp without time zone', 'timestamp with time zone')
GROUP BY data_type
ORDER BY data_type;
" 2>&1)"; then
    if [[ -z "$(echo "$pg_census" | tr -d '[:space:]')" ]]; then
      echo "No date/time columns found in user tables."
    else
      printf "data_type\tcolumns\ttables\n%s\n" "$pg_census" | column -t -s $'\t'
      echo
      echo "Only 'timestamp with time zone' and 'time with time zone' convert on input/"
      echo "output using the session timezone above. 'date', 'time without time zone', and"
      echo "'timestamp without time zone' are naive and store the literal value as-is."
      if echo "$pg_census" | grep -qi "with time zone"; then
        echo
        echo "NOTE: tz-aware columns exist. pgloader's default 'create tables' mapping for"
        echo "naive SQL Server datetime/datetime2 produces naive PostgreSQL columns, so any"
        echo "'with time zone' column here is worth checking — confirm it is intentional"
        echo "(e.g. mapped from datetimeoffset) and not an unexpected pgloader type choice."
      fi
    fi
  else
    echo "WARNING: could not query PostgreSQL column census:" >&2
    echo "$pg_census" >&2
    pg_ok=0
  fi
fi

##################################
# 5. Migrated value spot-check
##################################

section "5. Migrated date/time value comparison (per column, MIN/MAX/COUNT)"

if [[ "$mssql_ok" != "1" || "$pg_ok" != "1" ]]; then
  echo "Skipped: needs both SQL Server and PostgreSQL reachable (see warnings above)."
else
  mssql_dt_file="$tmpdir/mssql_datetime.tsv"
  pg_dt_file="$tmpdir/pg_datetime.tsv"

  echo "Reading SQL Server date/time values..." >&2

  run_sqlcmd "
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#results') IS NOT NULL
    DROP TABLE #results;

CREATE TABLE #results (
    table_key nvarchar(264),
    column_name sysname,
    data_type sysname,
    cnt bigint,
    min_val nvarchar(64),
    max_val nvarchar(64)
);

DECLARE
    @schema sysname, @table sysname, @column sysname, @type sysname,
    @sql nvarchar(max), @template nvarchar(200), @table_key nvarchar(264);

DECLARE col_cursor CURSOR FAST_FORWARD FOR
SELECT s.name, t.name, c.name, ty.name
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN ('date', 'time', 'smalldatetime', 'datetime', 'datetime2', 'datetimeoffset')
ORDER BY s.name, t.name, c.name;

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @schema, @table, @column, @type;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @type = 'date'
        SET @template = N'FORMAT(%s, ''yyyy-MM-dd'')';
    ELSE IF @type = 'time'
        SET @template = N'FORMAT(%s, ''HH:mm:ss.fff'')';
    ELSE IF @type = 'datetimeoffset'
        SET @template = N'FORMAT(SWITCHOFFSET(%s, ''+00:00''), ''yyyy-MM-dd HH:mm:ss.fff'')';
    ELSE
        SET @template = N'FORMAT(%s, ''yyyy-MM-dd HH:mm:ss.fff'')';

    SET @table_key = (CASE WHEN @schema = 'dbo' THEN 'public' ELSE @schema END) + N'.' + @table;

    SET @sql = N'
        INSERT INTO #results(table_key, column_name, data_type, cnt, min_val, max_val)
        SELECT @table_key, @column_name, @data_type, COUNT(' + QUOTENAME(@column) + N'),
            ' + REPLACE(@template, N'%s', N'MIN(' + QUOTENAME(@column) + N')') + N',
            ' + REPLACE(@template, N'%s', N'MAX(' + QUOTENAME(@column) + N')') + N'
        FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N';';

    EXEC sp_executesql
        @sql,
        N'@table_key nvarchar(264), @column_name sysname, @data_type sysname',
        @table_key = @table_key,
        @column_name = @column,
        @data_type = @type;

    FETCH NEXT FROM col_cursor INTO @schema, @table, @column, @type;
END

CLOSE col_cursor;
DEALLOCATE col_cursor;

SELECT
    LOWER(table_key COLLATE DATABASE_DEFAULT) + ':' +
    LOWER(column_name COLLATE DATABASE_DEFAULT),
    data_type,
    CAST(cnt AS varchar(20)),
    min_val,
    max_val
FROM #results
ORDER BY 1;
" | sed '/^[[:space:]]*$/d' | awk -F'\t' 'NF == 5' | sort -t $'\t' -k1,1 > "$mssql_dt_file"

  echo "Reading PostgreSQL date/time values..." >&2

  pg_select_sql="$(run_psql "
WITH cols AS (
  SELECT n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name,
         format_type(a.atttypid, a.atttypmod) AS data_type
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE a.attnum > 0 AND NOT a.attisdropped
    AND c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND format_type(a.atttypid, a.atttypmod) IN
        ('date', 'time without time zone', 'time with time zone',
         'timestamp without time zone', 'timestamp with time zone')
),
templated AS (
  SELECT schema_name, table_name, column_name, data_type,
    CASE data_type
      WHEN 'timestamp with time zone' THEN \$t\$to_char((%s) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS')\$t\$
      WHEN 'time with time zone'      THEN \$t\$to_char((%s) AT TIME ZONE 'UTC', 'HH24:MI:SS.MS')\$t\$
      WHEN 'date'                     THEN \$t\$to_char(%s, 'YYYY-MM-DD')\$t\$
      WHEN 'time without time zone'   THEN \$t\$to_char(%s, 'HH24:MI:SS.MS')\$t\$
      ELSE                                 \$t\$to_char(%s, 'YYYY-MM-DD HH24:MI:SS.MS')\$t\$
    END AS value_template
  FROM cols
)
SELECT string_agg(
  format(
    'SELECT %L::text AS composite_key, %L::text AS data_type, COUNT(%I)::text AS cnt, %s AS min_val, %s AS max_val FROM %I.%I',
    lower(schema_name) || '.' || lower(table_name) || ':' || lower(column_name),
    data_type,
    column_name,
    format(value_template, format('MIN(%I)', column_name)),
    format(value_template, format('MAX(%I)', column_name)),
    schema_name, table_name
  ),
  E'\nUNION ALL\n'
)
FROM templated;
")"

  if [[ -z "$pg_select_sql" ]]; then
    : > "$pg_dt_file"
  else
    pg_select_file="$tmpdir/pg_select.sql"
    printf '%s\nORDER BY 1;\n' "$pg_select_sql" > "$pg_select_file"
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -At -F $'\t' -f "$pg_select_file" \
      | sed '/^[[:space:]]*$/d' | awk -F'\t' 'NF == 5' | sort -t $'\t' -k1,1 > "$pg_dt_file"
  fi

  printf "%-60s %-26s %-26s %-12s %-26s %-26s %s\n" \
    "table.column" "mssql_type" "postgres_type" "count(ms/pg)" "min(ms/pg)" "max(ms/pg)" "status"

  while IFS=$'\t' read -r key mtype mcnt mmin mmax ptype pcnt pmin pmax; do
    total=$((total + 1))
    if [[ "$mcnt" == "MISSING" || "$pcnt" == "MISSING" ]]; then
      status="MISSING_IN_$([[ "$mcnt" == "MISSING" ]] && echo MSSQL || echo POSTGRES)"
    elif [[ "$mcnt" != "$pcnt" ]]; then
      status="COUNT_MISMATCH"
    elif [[ "$mcnt" == "0" ]]; then
      status="OK"
    elif [[ "$mmin" != "$pmin" || "$mmax" != "$pmax" ]]; then
      status="VALUE_MISMATCH"
    else
      status="OK"
    fi
    [[ "$status" != "OK" ]] && mismatches=$((mismatches + 1))

    printf "%-60s %-26s %-26s %-12s %-26s %-26s %s\n" \
      "$key" "$mtype" "$ptype" "${mcnt}/${pcnt}" "${mmin}/${pmin}" "${mmax}/${pmax}" "$status"
  done < <(join -t $'\t' -a 1 -a 2 -e MISSING \
    -o '0,1.2,1.3,1.4,1.5,2.2,2.3,2.4,2.5' \
    "$mssql_dt_file" "$pg_dt_file")

  echo
  if [[ "$total" -eq 0 ]]; then
    echo "No date/time columns found on either side; nothing to compare."
  else
    echo "Any status other than OK means the migrator did not move that column's"
    echo "values byte-for-byte: a count mismatch means rows are missing or duplicated;"
    echo "a value mismatch on a naive type means an unexpected shift occurred; a value"
    echo "mismatch on 'datetimeoffset' / 'timestamp with time zone' after UTC"
    echo "normalization means the source and target disagree about the instant in time,"
    echo "which is the actual timezone-correctness question for this migration."
    echo
    if [[ "$mismatches" -eq 0 ]]; then
      echo "VERDICT: PASS - all $total date/time column(s) match between SQL Server and PostgreSQL."
    else
      echo "VERDICT: FAIL - $mismatches of $total date/time column(s) do not match. See statuses above."
    fi
  fi
fi

##################################
# exit status reflects the verdict
##################################

if [[ "$mismatches" -gt 0 ]]; then
  exit 1
fi
exit 0
