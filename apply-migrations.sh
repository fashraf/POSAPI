#!/usr/bin/env bash
# Create or update the POSMAIN database from db-migrations/ — the Linux and
# macOS twin of apply-migrations.cmd. Same files, same tracking table, same
# options, so a database built by one can be updated by the other.
#
#   ./apply-migrations.sh -S 127.0.0.1,1433 -U sa -P 'Root@123'
#   ./apply-migrations.sh --docker sql2019 -U sa -P 'Root@123'
#
#   -S SERVER          server, default 127.0.0.1,1433 (localhost inside --docker)
#   -U USER -P PASS    SQL login; Linux has no Windows login, so a user is required
#   --docker NAME      run sqlcmd inside that SQL Server container instead of on
#                      this machine (no local sqlcmd needed; files are copied in)
#   --dry-run          list what would run; change nothing
#   --demo             also load 900-demo-data.sql (demo company, users with
#                      password 1234). Only on a database this run creates.
#   --adopt            take over a database built by the old migration files
#                      (11-43): record 001 and 002 as already applied
#   --recreate         DROP POSMAIN and build it again from scratch
#   --yes              do not ask before --recreate drops the database
#
# The server and login can also come from POS_SQL_SERVER, POS_SQL_USER and
# POS_SQL_PASSWORD (and the container from POS_SQL_DOCKER), which keeps a
# password out of shell history.
#
# Files, in name order:
#   001-899  migrations. Each runs once and is recorded in dbo.SchemaMigration.
#   900-998  optional data, run only with --demo on a new database.
#   999      read-only health check, run after every apply.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIG="$HERE/db-migrations"

SERVER="${POS_SQL_SERVER:-}"
SQLUSER="${POS_SQL_USER:-}"
SQLPASS="${POS_SQL_PASSWORD:-}"
DOCKER="${POS_SQL_DOCKER:-}"
DEMO=""; DRYRUN=""; ADOPT=""; RECREATE=""; YES=""
CREATED=""; ADOPTING=""
APPLIED=0; PENDING=0

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -S)         SERVER="${2:-}"; shift 2 ;;
        -U)         SQLUSER="${2:-}"; shift 2 ;;
        -P)         SQLPASS="${2:-}"; shift 2 ;;
        --docker)   DOCKER="${2:-}"; shift 2 ;;
        --demo)     DEMO=1; shift ;;
        --dry-run)  DRYRUN=1; shift ;;
        --adopt)    ADOPT=1; shift ;;
        --recreate) RECREATE=1; shift ;;
        --yes)      YES=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown option: $1"; echo "Run with --help for usage."; exit 2 ;;
    esac
done

if [ -n "$ADOPT" ] && [ -n "$RECREATE" ]; then
    echo "--adopt keeps the database and --recreate drops it. Choose one."
    exit 2
fi
if [ -z "$SQLUSER" ]; then
    echo "A SQL login is required: -U user -P password (or POS_SQL_USER / POS_SQL_PASSWORD)."
    exit 2
fi
if [ -z "$SERVER" ]; then
    if [ -n "$DOCKER" ]; then SERVER="localhost"; else SERVER="127.0.0.1,1433"; fi
fi

# ------------------------------------------------------------------ sqlcmd
# Either the local sqlcmd or the one inside the container. The password goes
# in SQLCMDPASSWORD rather than -P, so it does not show up in the process list.
SQLCMD_BIN=""
if [ -n "$DOCKER" ]; then
    if ! docker inspect -f '{{.State.Running}}' "$DOCKER" 2>/dev/null | grep -q true; then
        echo "Container '$DOCKER' is not running (docker start $DOCKER)."
        exit 1
    fi
    for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
        if docker exec "$DOCKER" test -x "$candidate" 2>/dev/null; then SQLCMD_BIN="$candidate"; break; fi
    done
    if [ -z "$SQLCMD_BIN" ]; then
        echo "No sqlcmd found inside container '$DOCKER'."
        exit 1
    fi
else
    for candidate in sqlcmd /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
        if command -v "$candidate" >/dev/null 2>&1; then SQLCMD_BIN="$(command -v "$candidate")"; break; fi
    done
    if [ -z "$SQLCMD_BIN" ]; then
        echo "sqlcmd was not found. Install Microsoft's sqlcmd (mssql-tools18 or go-sqlcmd),"
        echo "or run against a SQL Server container with --docker <name>."
        exit 1
    fi
fi

# -b  stop and fail on the first error
# -I  QUOTED_IDENTIFIER ON; filtered indexes fail without it
# -C  trust the server certificate (not understood by the old mssql-tools 17)
# -f  read the files as UTF-8, or every Arabic string is stored garbled
SQLCMD_ARGS=(-S "$SERVER" -U "$SQLUSER" -b -I -f 65001)
case "$SQLCMD_BIN" in */mssql-tools/bin/*) ;; *) SQLCMD_ARGS+=(-C) ;; esac

# sql DB ARGS...  — run sqlcmd against database DB.
sql() {
    local db="$1"; shift
    if [ -n "$DOCKER" ]; then
        docker exec -e SQLCMDPASSWORD="$SQLPASS" "$DOCKER" "$SQLCMD_BIN" "${SQLCMD_ARGS[@]}" -d "$db" "$@"
    else
        SQLCMDPASSWORD="$SQLPASS" "$SQLCMD_BIN" "${SQLCMD_ARGS[@]}" -d "$db" "$@"
    fi
}

# scalar DB QUERY  — the last non-empty line of a one-value query.
scalar() {
    sql "$1" -h -1 -W -Q "SET NOCOUNT ON; $2" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '\r[:space:]'
}

# run_file NAME  — run one migration file (from master: 001 creates POSMAIN
# itself, and every file says USE POSMAIN).
run_file() {
    local file="$MIG/$1"
    if [ -n "$DOCKER" ]; then
        local remote="/tmp/pos-migration-$$-$1"
        docker cp "$file" "$DOCKER:$remote" >/dev/null || return 1
        sql master -i "$remote"
        local rc=$?
        docker exec -u 0 "$DOCKER" rm -f "$remote" >/dev/null 2>&1
        return $rc
    fi
    sql master -i "$file"
}

ensure_tracking() {
    sql POSMAIN -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL CREATE TABLE dbo.SchemaMigration (FileName NVARCHAR(200) NOT NULL CONSTRAINT PK_SchemaMigration PRIMARY KEY, AppliedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_SchemaMigration_At DEFAULT SYSUTCDATETIME(), AppliedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_SchemaMigration_By DEFAULT SUSER_SNAME(), Baselined BIT NOT NULL CONSTRAINT DF_SchemaMigration_Baselined DEFAULT 0);" >/dev/null
}

fail() {
    echo
    echo "=== FAILED: $1 - the error is above. Nothing after it was run. ==="
    echo "Fix the cause and run this again; files already applied are skipped."
    exit 1
}

echo
echo "Server:     $SERVER${DOCKER:+  (inside container $DOCKER)}"
echo "Login:      $SQLUSER"
echo "Migrations: $MIG"
[ -n "$DRYRUN" ] && echo "Mode:       dry run - nothing will be changed"
echo

if ! sql master -h -1 -Q "SET NOCOUNT ON; SELECT 1;" >/dev/null; then
    echo "Could not connect to $SERVER. The error is above."
    exit 1
fi

# --------------------------------------------------------------- what is there
# missing  no POSMAIN database
# empty    POSMAIN exists with no schema
# tracked  built from 001 by this script (or the .cmd)
# legacy   built by the old migration files, before 001 existed
STATE="$(scalar master "IF DB_ID(N'POSMAIN') IS NULL SELECT N'missing' ELSE EXEC (N'USE POSMAIN; IF OBJECT_ID(N''dbo.SchemaMigration'') IS NULL SELECT CASE WHEN SCHEMA_ID(N''core'') IS NULL THEN N''empty'' ELSE N''legacy'' END ELSE SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE FileName = N''001-baseline-schema.sql'') THEN N''tracked'' WHEN SCHEMA_ID(N''core'') IS NULL THEN N''empty'' ELSE N''legacy'' END');")"

case "$STATE" in
    missing|empty|tracked|legacy) ;;
    *) echo "Could not tell what state POSMAIN is in."; exit 1 ;;
esac
echo "Database:   POSMAIN is $STATE"
echo

recreate() {
    local sales
    sales="$(scalar POSMAIN "IF OBJECT_ID(N'sales.Sale') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM sales.Sale;")"
    if [ -n "$DRYRUN" ]; then
        echo "Would DROP POSMAIN (${sales:-0} sale(s) in it) and build it again."
        STATE=missing; CREATED=1
        return
    fi
    echo "--recreate will DROP the POSMAIN database on $SERVER."
    echo "It holds ${sales:-0} sale(s). Everything in it is deleted."
    if [ -z "$YES" ]; then
        local confirm=""
        read -r -p "Type POSMAIN to confirm: " confirm || true
        if [ "$confirm" != "POSMAIN" ]; then
            echo "Not confirmed. Nothing was changed."
            exit 1
        fi
    fi
    sql master -h -1 -Q "SET NOCOUNT ON; ALTER DATABASE POSMAIN SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE POSMAIN;" \
        || fail "dropping POSMAIN"
    echo "POSMAIN dropped."
    echo
    STATE=missing; CREATED=1
}

adopt() {
    # Adopting is only honest if the schema really is the final one. The two
    # newest old migrations each left a parameter only they add.
    local final
    final="$(scalar POSMAIN "SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'sales.usp_CommitSale')) LIKE N'%@CashDueH%' AND OBJECT_DEFINITION(OBJECT_ID(N'core.usp_RegisterBusiness')) LIKE N'%@PasswordHash%' AND COL_LENGTH(N'sales.Sale', N'OrderType') IS NOT NULL THEN 1 ELSE 0 END;")"
    if [ "$final" != "1" ]; then
        echo "Cannot adopt: this database stopped before the last old migration"
        echo "(42 or 43 is missing), so its schema does not match 001."
        echo "Use --recreate to rebuild it."
        exit 1
    fi
    if [ -n "$DRYRUN" ]; then
        echo "Would record 001 and 002 as already applied."
        ADOPTING=1
        return
    fi
    ensure_tracking || fail "creating dbo.SchemaMigration"
    sql POSMAIN -h -1 -Q "SET NOCOUNT ON; INSERT INTO dbo.SchemaMigration (FileName, Baselined) SELECT v.f, 1 FROM (VALUES (N'001-baseline-schema.sql'), (N'002-reference-data.sql')) AS v (f) WHERE NOT EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE FileName = v.f);" >/dev/null \
        || fail "recording the adoption"
    echo "Adopted: 001 and 002 recorded as already applied."
    echo
}

if [ -n "$RECREATE" ] && [ "$STATE" != "missing" ]; then
    recreate
elif [ "$STATE" = "legacy" ]; then
    if [ -n "$ADOPT" ]; then
        adopt
    else
        echo "POSMAIN was built by the old migration files (11-43), which 001 and 002"
        echo "replaced. Choose one:"
        echo
        echo "  --adopt     the database has every old migration applied (through 43)."
        echo "              Its schema already matches 001; it is recorded as such."
        echo "  --recreate  DROP the database and build it again. Use this when an old"
        echo "              migration failed part-way, or the data is only test data."
        exit 1
    fi
fi

[ "$STATE" = "missing" ] || [ "$STATE" = "empty" ] && CREATED=1

if [ -n "$DEMO" ] && [ -z "$CREATED" ]; then
    echo "--demo only loads into a database this run creates. POSMAIN already"
    echo "exists; add --recreate to rebuild it with the demo data."
    exit 2
fi

# ------------------------------------------------------------------ migrations
shopt -s nullglob
files=()
for path in "$MIG"/[0-9][0-9][0-9]-*.sql; do files+=("$(basename "$path")"); done
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | LC_ALL=C sort)); unset IFS

for file in "${files[@]}"; do
    prefix="${file:0:3}"

    # 999 is the health check, run once at the end.
    [ "$prefix" = "999" ] && continue

    # A dry run of --adopt: these two would be recorded, not run.
    if [ -n "$ADOPTING" ] && { [ "$prefix" = "001" ] || [ "$prefix" = "002" ]; }; then continue; fi

    # 900-998: optional data, only into a database this run created.
    if [ "${prefix:0:1}" = "9" ]; then
        [ -n "$DEMO" ] && [ -n "$CREATED" ] || continue
    fi

    done_count=0
    if ! { [ -n "$CREATED" ] && [ -n "$DRYRUN" ]; }; then
        done_count="$(scalar POSMAIN "IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.SchemaMigration WHERE FileName = N'$file';")"
    fi
    [ "$done_count" = "1" ] && continue

    if [ -n "$DRYRUN" ]; then
        echo "Pending:  $file"
        PENDING=$((PENDING + 1))
        continue
    fi

    echo "Applying: $file"
    run_file "$file" || fail "$file"
    ensure_tracking || fail "creating dbo.SchemaMigration"
    sql POSMAIN -h -1 -Q "SET NOCOUNT ON; INSERT INTO dbo.SchemaMigration (FileName) VALUES (N'$file');" >/dev/null \
        || { echo "Applied $file but could not record it."; fail "$file"; }
    APPLIED=$((APPLIED + 1))
done

echo
if [ -n "$DRYRUN" ]; then
    echo "$PENDING file(s) would run."
    exit 0
fi

if [ "$APPLIED" = "0" ]; then echo "The database is up to date."; else echo "Applied $APPLIED file(s)."; fi

if [ -f "$MIG/999-verify-install.sql" ]; then
    echo
    echo "Verifying the install..."
    run_file "999-verify-install.sql"
fi
exit 0
