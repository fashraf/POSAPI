#!/usr/bin/env bash
# Create or update the posmain database from db-migrations/ — the Linux and
# macOS twin of apply-migrations.cmd, and the shell twin of the API's own
# runner (src/PosApi/Tenancy/SqlScriptRunner.cs). Same files, same tracking
# table, so a database built by one can be updated by the others.
#
#   POS_PG_PASSWORD='Root@123' ./apply-migrations.sh -h 127.0.0.1 -p 5432 -U postgres
#   ./apply-migrations.sh --docker pos-pg16 -U postgres --demo
#
#   -h HOST            server, default 127.0.0.1 (the container's own socket
#                      inside --docker)
#   -p PORT            port, default 5432
#   -U USER            PostgreSQL role, default postgres. It needs CREATEDB to
#                      create the database.
#   -d DATABASE        database, default posmain. Names are lower case.
#   --docker NAME      run psql inside that PostgreSQL container instead of on
#                      this machine (no local psql needed; files are piped in)
#   --dry-run          list what would run; change nothing
#   --demo             also load 900-demo-data.sql (demo company, users with
#                      password 1234). Only on a database this run creates.
#   --recreate         DROP the database and build it again from scratch
#   --yes              do not ask before --recreate drops the database
#
# The password comes from POS_PG_PASSWORD (or PGPASSWORD, or ~/.pgpass), never
# the command line, which keeps it out of shell history and the process list.
# The server, port, role, database and container can also come from
# POS_PG_HOST, POS_PG_PORT, POS_PG_USER, POS_PG_DATABASE and POS_PG_DOCKER.
#
# Files, in name order:
#   001-899  migrations. Each runs once, in a transaction of its own, and is
#            recorded in dbo.SchemaMigration in that same transaction: a file
#            that fails leaves the database as it was before it.
#   900-998  optional data, run only with --demo on a new database.
#   999      read-only health check, run after every apply.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIG="$HERE/db-migrations"

PGHOSTNAME="${POS_PG_HOST:-}"
PGPORTNUM="${POS_PG_PORT:-}"
PGROLE="${POS_PG_USER:-postgres}"
PGPASS="${POS_PG_PASSWORD:-${PGPASSWORD:-}}"
DB="${POS_PG_DATABASE:-posmain}"
DOCKER="${POS_PG_DOCKER:-}"
DEMO=""; DRYRUN=""; RECREATE=""; YES=""
CREATED=""
APPLIED=0; PENDING=0

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h)         PGHOSTNAME="${2:-}"; shift 2 ;;
        -p)         PGPORTNUM="${2:-}"; shift 2 ;;
        -U)         PGROLE="${2:-}"; shift 2 ;;
        -d)         DB="${2:-}"; shift 2 ;;
        --docker)   DOCKER="${2:-}"; shift 2 ;;
        --demo)     DEMO=1; shift ;;
        --dry-run)  DRYRUN=1; shift ;;
        --recreate) RECREATE=1; shift ;;
        --yes)      YES=1; shift ;;
        --help)     usage; exit 0 ;;
        --adopt)    echo "--adopt is gone: there are no SQL Server-era databases to take over in PostgreSQL."
                    exit 2 ;;
        *)          echo "Unknown option: $1"; echo "Run with --help for usage."; exit 2 ;;
    esac
done

# PostgreSQL folds unquoted names to lower case; the API does the same.
DB="$(printf '%s' "$DB" | tr '[:upper:]' '[:lower:]')"
if ! printf '%s' "$DB" | grep -Eq '^[a-z][a-z0-9_]{0,62}$'; then
    echo "'$DB' is not a valid database name: letters, digits and _, starting with a letter."
    exit 2
fi
if [ -z "$PGROLE" ]; then
    echo "A PostgreSQL role is required: -U user (or POS_PG_USER)."
    exit 2
fi
if [ -z "$PGHOSTNAME" ] && [ -z "$DOCKER" ]; then PGHOSTNAME="127.0.0.1"; fi
if [ -z "$PGPORTNUM" ]; then PGPORTNUM="5432"; fi

# -------------------------------------------------------------------- psql
# Either the local psql or the one inside the container. The password goes
# in PGPASSWORD rather than on the command line.
if [ -n "$DOCKER" ]; then
    if ! docker inspect -f '{{.State.Running}}' "$DOCKER" 2>/dev/null | grep -q true; then
        echo "Container '$DOCKER' is not running (docker start $DOCKER)."
        exit 1
    fi
    if ! docker exec "$DOCKER" sh -c 'command -v psql' >/dev/null 2>&1; then
        echo "No psql found inside container '$DOCKER'."
        exit 1
    fi
else
    if ! command -v psql >/dev/null 2>&1; then
        echo "psql was not found. Install the PostgreSQL client (postgresql-client),"
        echo "or run against a PostgreSQL container with --docker <name>."
        exit 1
    fi
fi

# -X                 ignore ~/.psqlrc, so nobody's settings change the run
# -w                 never prompt for a password (fail instead of hanging)
# ON_ERROR_STOP=1    stop and fail on the first error
# PGCLIENTENCODING   read the files as UTF-8, or every Arabic string is garbled
PSQL_ARGS=(-X -w -q -v ON_ERROR_STOP=1 -p "$PGPORTNUM" -U "$PGROLE")
[ -n "$PGHOSTNAME" ] && PSQL_ARGS+=(-h "$PGHOSTNAME")

# READONLY=1 makes the session refuse every write (used for 999).
READONLY=""

# pg DB ARGS...  — run psql against database DB; stdin passes through.
pg() {
    local db="$1"; shift
    local options=""
    [ -n "$READONLY" ] && options="-c default_transaction_read_only=on"
    if [ -n "$DOCKER" ]; then
        docker exec -i -e PGPASSWORD="$PGPASS" -e PGCLIENTENCODING=UTF8 -e PGOPTIONS="$options" \
            "$DOCKER" psql "${PSQL_ARGS[@]}" -d "$db" "$@"
    else
        PGPASSWORD="$PGPASS" PGCLIENTENCODING=UTF8 PGOPTIONS="$options" \
            psql "${PSQL_ARGS[@]}" -d "$db" "$@"
    fi
}

# scalar DB QUERY  — the single value a one-row, one-column query returns.
scalar() {
    pg "$1" -At -c "$2" 2>/dev/null | tr -d '\r[:space:]'
}

# The tracking table, exactly as SqlScriptRunner creates it.
TRACKING_SQL="CREATE SCHEMA IF NOT EXISTS dbo;
CREATE TABLE IF NOT EXISTS dbo.SchemaMigration (
    FileName     varchar(200) NOT NULL PRIMARY KEY,
    AppliedAtUtc timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    AppliedBy    varchar(128) NOT NULL DEFAULT current_user);"

# run_file NAME  — run one migration and record it, in one transaction. The
# file and the INSERT go down the same pipe into one psql --single-transaction,
# so either both are committed or neither is.
run_file() {
    local name="$1"
    local quoted="${name//\'/\'\'}"
    {
        cat "$MIG/$name"
        printf '\n;\nSET LOCAL client_min_messages = warning;\n%s\nINSERT INTO dbo.SchemaMigration (FileName) VALUES (%s) ON CONFLICT (FileName) DO NOTHING;\n' \
            "$TRACKING_SQL" "'$quoted'"
    } | pg "$DB" --single-transaction -f -
}

fail() {
    echo
    echo "=== FAILED: $1 - the error is above. Nothing after it was run. ==="
    echo "Fix the cause and run this again; files already applied are skipped."
    exit 1
}

echo
if [ -n "$PGHOSTNAME" ]; then SERVER="$PGHOSTNAME:$PGPORTNUM"; else SERVER="local socket, port $PGPORTNUM"; fi
echo "Server:     $SERVER${DOCKER:+  (inside container $DOCKER)}"
echo "Role:       $PGROLE"
echo "Migrations: $MIG"
[ -n "$DRYRUN" ] && echo "Mode:       dry run - nothing will be changed"
echo

if ! pg postgres -c "SELECT 1;" >/dev/null; then
    echo "Could not connect to $SERVER. The error is above."
    exit 1
fi

# --------------------------------------------------------------- what is there
# missing    no database of that name
# empty      the database exists with no schema
# tracked    built from these files, by this script, the .cmd or the API
# untracked  holds a POS schema that no runner recorded
EXISTS="$(scalar postgres "SELECT count(*) FROM pg_database WHERE datname = '$DB';")"
if [ "$EXISTS" = "0" ]; then
    STATE=missing
elif [ "$EXISTS" = "1" ]; then
    STATE="$(scalar "$DB" "SELECT CASE WHEN to_regclass('dbo.schemamigration') IS NOT NULL THEN 'tracked' WHEN to_regnamespace('core') IS NULL THEN 'empty' ELSE 'untracked' END;")"
else
    STATE=""
fi

case "$STATE" in
    missing|empty|tracked|untracked) ;;
    *) echo "Could not tell what state $DB is in."; exit 1 ;;
esac
echo "Database:   $DB is $STATE"
echo

recreate() {
    local sales
    sales="$(scalar "$DB" "SELECT CASE WHEN to_regclass('sales.sale') IS NULL THEN 0 ELSE (SELECT count(*) FROM sales.Sale) END;")"
    if [ -n "$DRYRUN" ]; then
        echo "Would DROP $DB (${sales:-0} sale(s) in it) and build it again."
        STATE=missing; CREATED=1
        return
    fi
    echo "--recreate will DROP the $DB database on $SERVER."
    echo "It holds ${sales:-0} sale(s). Everything in it is deleted."
    if [ -z "$YES" ]; then
        local confirm=""
        read -r -p "Type $DB to confirm: " confirm || true
        if [ "$confirm" != "$DB" ]; then
            echo "Not confirmed. Nothing was changed."
            exit 1
        fi
    fi
    # WITH (FORCE) closes the connections still open to it, the API's included.
    pg postgres -c "DROP DATABASE $DB WITH (FORCE);" || fail "dropping $DB"
    echo "$DB dropped."
    echo
    STATE=missing; CREATED=1
}

if [ -n "$RECREATE" ] && [ "$STATE" != "missing" ]; then
    recreate
elif [ "$STATE" = "untracked" ]; then
    echo "$DB has a POS schema but no dbo.SchemaMigration, so nothing records which"
    echo "files built it. It was not made by these files (or by the API)."
    echo
    echo "  --recreate  DROP the database and build it again. Use this when the data"
    echo "              is only test data."
    exit 1
fi

[ "$STATE" = "missing" ] || [ "$STATE" = "empty" ] && CREATED=1

if [ -n "$DEMO" ] && [ -z "$CREATED" ]; then
    echo "--demo only loads into a database this run creates. $DB already"
    echo "exists; add --recreate to rebuild it with the demo data."
    exit 2
fi

if [ "$STATE" = "missing" ]; then
    if [ -n "$DRYRUN" ]; then
        echo "Would create $DB (UTF8)."
    else
        # UTF-8 whatever the server's default; template0 because template1 may
        # carry another encoding or objects someone added to it.
        pg postgres -c "CREATE DATABASE $DB ENCODING 'UTF8' TEMPLATE template0;" || fail "creating $DB"
        echo "Created $DB."
    fi
    echo
fi

# ------------------------------------------------------------------ migrations
shopt -s nullglob
files=()
for path in "$MIG"/[0-9][0-9][0-9]-*.sql; do files+=("$(basename "$path")"); done
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | LC_ALL=C sort)); unset IFS

# What has already run (nothing, on a database this run creates).
applied=""
if [ "$STATE" = "tracked" ]; then
    applied="$(pg "$DB" -At -c "SELECT FileName FROM dbo.SchemaMigration;")" \
        || fail "reading dbo.SchemaMigration"
fi

for file in "${files[@]}"; do
    prefix="${file:0:3}"

    # 999 is the health check, run once at the end.
    [ "$prefix" = "999" ] && continue

    # 900-998: optional data, only into a database this run created.
    if [ "${prefix:0:1}" = "9" ]; then
        [ -n "$DEMO" ] && [ -n "$CREATED" ] || continue
    fi

    # Compared ignoring case, as the ci collation of FileName does.
    if [ -n "$applied" ] && printf '%s\n' "$applied" | grep -Fxiq -- "$file"; then continue; fi

    if [ -n "$DRYRUN" ]; then
        echo "Pending:  $file"
        PENDING=$((PENDING + 1))
        continue
    fi

    echo "Applying: $file"
    run_file "$file" || fail "$file"
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
    READONLY=1
    pg "$DB" -At -f - < "$MIG/999-verify-install.sql"
    READONLY=""
fi
exit 0
