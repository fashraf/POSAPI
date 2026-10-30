@echo off
REM Create or update the posmain database from db-migrations\ - the Windows twin
REM of apply-migrations.sh. Same files, same tracking table as the script and
REM the API, so a database built by one can be updated by the others.
REM
REM   set POS_PG_PASSWORD=Root@123
REM   apply-migrations.cmd                                  127.0.0.1:5432, role postgres
REM   apply-migrations.cmd -h db.example.local -p 5432 -U pos
REM   apply-migrations.cmd --docker pos-pg16 --demo
REM
REM   -h HOST        server, default 127.0.0.1 (the container's own socket
REM                  inside --docker)
REM   -p PORT        port, default 5432
REM   -U USER        PostgreSQL role, default postgres. It needs CREATEDB to
REM                  create the database.
REM   -d DATABASE    database, default posmain. Names are lower case.
REM   --docker NAME  run psql inside that PostgreSQL container instead of on
REM                  this machine (no local psql needed; files are copied in)
REM   --dry-run      list what would run; change nothing
REM   --demo         also load 900-demo-data.sql (demo company, users with
REM                  password 1234). Only on a database this run creates.
REM   --recreate     DROP the database and build it again from scratch
REM   --yes          do not ask before --recreate drops the database
REM   --no-pause     for CI or a scheduled task
REM
REM The password comes from POS_PG_PASSWORD (or PGPASSWORD, or pgpass.conf),
REM never the command line, which keeps it out of the process list. The server,
REM port, role, database and container can also come from POS_PG_HOST,
REM POS_PG_PORT, POS_PG_USER, POS_PG_DATABASE and POS_PG_DOCKER.
REM
REM Needs psql 10 or later (psql.exe from the PostgreSQL installer, on PATH).
REM
REM Files, in name order:
REM   001-899  migrations. Each runs once, in a transaction of its own, and is
REM            recorded in dbo.SchemaMigration in that same transaction: a file
REM            that fails leaves the database as it was before it.
REM   900-998  optional data, run only with --demo on a new database.
REM   999      read-only health check, run after every apply.

setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

set "MIG=%~dp0db-migrations"
set "HOST=%POS_PG_HOST%"
set "PORT=%POS_PG_PORT%"
set "ROLE=%POS_PG_USER%"
set "DB=%POS_PG_DATABASE%"
set "DOCKER=%POS_PG_DOCKER%"
if defined POS_PG_PASSWORD set "PGPASSWORD=%POS_PG_PASSWORD%"
set "DEMO="
set "DRYRUN="
set "RECREATE="
set "YES="
set "NOPAUSE="
set "CREATED="
set "RC=0"
set "OLDCP="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="-h"         (set "HOST=%~2"    & shift & shift & goto parse)
if /i "%~1"=="-p"         (set "PORT=%~2"    & shift & shift & goto parse)
if /i "%~1"=="-U"         (set "ROLE=%~2"    & shift & shift & goto parse)
if /i "%~1"=="-d"         (set "DB=%~2"      & shift & shift & goto parse)
if /i "%~1"=="--docker"   (set "DOCKER=%~2"  & shift & shift & goto parse)
if /i "%~1"=="--demo"     (set "DEMO=1"      & shift & goto parse)
if /i "%~1"=="--dry-run"  (set "DRYRUN=1"    & shift & goto parse)
if /i "%~1"=="--recreate" (set "RECREATE=1"  & shift & goto parse)
if /i "%~1"=="--yes"      (set "YES=1"       & shift & goto parse)
if /i "%~1"=="--no-pause" (set "NOPAUSE=1"   & shift & goto parse)
if /i "%~1"=="--adopt" (
    echo --adopt is gone: there are no SQL Server-era databases to take over in PostgreSQL.
    set "RC=2"
    goto finish
)
echo Unknown option: %~1
echo See the comments at the top of this file for usage.
set "RC=2"
goto finish

:parsed
if not defined DB set "DB=posmain"
if not defined ROLE set "ROLE=postgres"
if not defined PORT set "PORT=5432"
if not defined DOCKER if not defined HOST set "HOST=127.0.0.1"

REM PostgreSQL folds unquoted names to lower case; the API does the same.
REM (A substitution in cmd ignores case, so A=a lower-cases both.)
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do call set "DB=%%DB:%%L=%%L%%"
echo %DB%| findstr /r /x "[abcdefghijklmnopqrstuvwxyz][abcdefghijklmnopqrstuvwxyz0123456789_]*" >nul
if errorlevel 1 (
    echo '%DB%' is not a valid database name: letters, digits and _, starting with a letter.
    set "RC=2"
    goto finish
)

REM psql reads the connection from these. Inside --docker they are passed on
REM by name (docker exec -e NAME), so the password never appears on a command
REM line. PGCLIENTENCODING: read the files as UTF-8, or every Arabic string is
REM stored garbled.
set "PGHOST=%HOST%"
set "PGPORT=%PORT%"
set "PGUSER=%ROLE%"
set "PGCLIENTENCODING=UTF8"
set "PGOPTIONS="

REM -X                ignore psqlrc, so nobody's settings change the run
REM -w                never prompt for a password (fail instead of hanging)
REM ON_ERROR_STOP=1   stop and fail on the first error
if defined DOCKER (
    set "PSQL=docker exec -i -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGCLIENTENCODING -e PGOPTIONS %DOCKER% psql -X -w -q -v ON_ERROR_STOP=1"
) else (
    set "PSQL=psql -X -w -q -v ON_ERROR_STOP=1"
)

if defined DOCKER goto check_docker
where psql >nul 2>&1
if errorlevel 1 (
    echo psql was not found on PATH.
    echo Install the PostgreSQL command line tools ^(the PostgreSQL installer, "Command Line Tools"^),
    echo add its bin folder to PATH, or run against a container with --docker ^<name^>.
    set "RC=1"
    goto finish
)
goto tools_ok

:check_docker
set "RUNNING="
for /f "usebackq delims=" %%R in (`docker inspect -f "{{.State.Running}}" "%DOCKER%" 2^>nul`) do set "RUNNING=%%R"
if not "%RUNNING%"=="true" (
    echo Container '%DOCKER%' is not running ^(docker start %DOCKER%^).
    set "RC=1"
    goto finish
)

:tools_ok
REM Show Arabic notices from the demo data properly in this console; the
REM console's own code page comes back at the end.
for /f "tokens=2 delims=:." %%C in ('chcp') do set "OLDCP=%%C"
chcp 65001 >nul

REM The tracking table, exactly as SqlScriptRunner creates it.
set "TRACK=SET LOCAL client_min_messages = warning; CREATE SCHEMA IF NOT EXISTS dbo; CREATE TABLE IF NOT EXISTS dbo.SchemaMigration (FileName varchar(200) NOT NULL PRIMARY KEY, AppliedAtUtc timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'), AppliedBy varchar(128) NOT NULL DEFAULT current_user);"

if defined HOST (set "SERVER=%HOST%:%PORT%") else (set "SERVER=local socket, port %PORT%")

echo.
if defined DOCKER (echo Server:     %SERVER%  ^(inside container %DOCKER%^)) else (echo Server:     %SERVER%)
echo Role:       %ROLE%
echo Migrations: %MIG%
if defined DRYRUN echo Mode:       dry run - nothing will be changed
echo.

%PSQL% -d postgres -c "SELECT 1;" >nul
if errorlevel 1 (
    echo Could not connect to %SERVER%. The error is above.
    set "RC=1"
    goto finish
)

REM -------------------------------------------------------------- what is there
REM missing    no database of that name
REM empty      the database exists with no schema
REM tracked    built from these files, by this script, the .sh or the API
REM untracked  holds a POS schema that no runner recorded
:detect
set "EXISTS="
for /f "usebackq delims=" %%R in (`%PSQL% -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = '%DB%';"`) do set "EXISTS=%%R"
set "STATE="
if "%EXISTS%"=="0" set "STATE=missing"
if "%EXISTS%"=="1" for /f "usebackq delims=" %%R in (`%PSQL% -d %DB% -At -c "SELECT CASE WHEN to_regclass('dbo.schemamigration') IS NOT NULL THEN 'tracked' WHEN to_regnamespace('core') IS NULL THEN 'empty' ELSE 'untracked' END;"`) do set "STATE=%%R"

if not defined STATE (
    echo Could not tell what state %DB% is in. The error is above.
    set "RC=1"
    goto finish
)
echo Database:   %DB% is %STATE%
echo.

if defined RECREATE if not "%STATE%"=="missing" goto recreate
if "%STATE%"=="untracked" goto untracked
if "%STATE%"=="missing" set "CREATED=1"
if "%STATE%"=="empty" set "CREATED=1"
if defined DEMO if not defined CREATED (
    echo --demo only loads into a database this run creates. %DB% already
    echo exists; add --recreate to rebuild it with the demo data.
    set "RC=2"
    goto finish
)
goto create

REM --------------------------------------------------------------- untracked
:untracked
echo %DB% has a POS schema but no dbo.SchemaMigration, so nothing records which
echo files built it. It was not made by these files ^(or by the API^).
echo.
echo   --recreate  DROP the database and build it again. Use this when the data
echo               is only test data.
set "RC=1"
goto finish

REM ---------------------------------------------------------------- recreate
:recreate
set "SALES=0"
for /f "usebackq delims=" %%R in (`%PSQL% -d %DB% -At -c "SELECT CASE WHEN to_regclass('sales.sale') IS NULL THEN 0 ELSE (SELECT count(*) FROM sales.Sale) END;"`) do set "SALES=%%R"
if defined DRYRUN (
    echo Would DROP %DB% ^(%SALES% sale^(s^) in it^) and build it again.
    set "STATE=missing"
    set "CREATED=1"
    goto create
)
echo --recreate will DROP the %DB% database on %SERVER%.
echo It holds %SALES% sale^(s^). Everything in it is deleted.
if defined YES goto drop
set "CONFIRM="
set /p "CONFIRM=Type %DB% to confirm: "
if not "%CONFIRM%"=="%DB%" (
    echo Not confirmed. Nothing was changed.
    set "RC=1"
    goto finish
)

:drop
REM WITH (FORCE) closes the connections still open to it, the API's included.
%PSQL% -d postgres -c "DROP DATABASE %DB% WITH (FORCE);"
if errorlevel 1 (
    set "FAILED=dropping %DB%"
    goto failed
)
echo %DB% dropped.
echo.
set "STATE=missing"
set "CREATED=1"

REM ------------------------------------------------------------------ create
:create
if not "%STATE%"=="missing" goto migrate
if defined DRYRUN (
    echo Would create %DB% ^(UTF8^).
    echo.
    goto migrate
)
REM UTF-8 whatever the server's default; template0 because template1 may carry
REM another encoding or objects someone added to it.
%PSQL% -d postgres -c "CREATE DATABASE %DB% ENCODING 'UTF8' TEMPLATE template0;"
if errorlevel 1 (
    set "FAILED=creating %DB%"
    goto failed
)
echo Created %DB%.
echo.

REM ------------------------------------------------------------- migrations
:migrate
set "FAILED="
set "APPLIED=0"
set "PENDING=0"
for /f "delims=" %%F in ('dir /b /a-d /on "%MIG%\*.sql" ^| findstr /r /b /c:"[0-9][0-9][0-9]-"') do call :apply "%%F"

echo.
if defined FAILED goto failed

if defined DRYRUN (
    echo %PENDING% file^(s^) would run.
    goto finish
)

if "%APPLIED%"=="0" (echo The database is up to date.) else (echo Applied %APPLIED% file^(s^).)

if not exist "%MIG%\999-verify-install.sql" goto finish
echo.
echo Verifying the install...
REM A read-only session: 999 must never change anything.
set "PGOPTIONS=-c default_transaction_read_only=on"
call :source "999-verify-install.sql"
%PSQL% -d %DB% -At -f "%SRC%"
call :cleanup "999-verify-install.sql"
set "PGOPTIONS="
goto finish

REM ------------------------------------------------------------------ :apply
:apply
if defined FAILED goto :eof
set "FILE=%~1"
set "PREFIX=%FILE:~0,3%"

REM 999 is the health check, run once at the end.
if "%PREFIX%"=="999" goto :eof

REM 900-998: optional data, only into a database this run created.
if "%PREFIX:~0,1%"=="9" (
    if not defined DEMO goto :eof
    if not defined CREATED goto :eof
)

REM A database this run creates has run nothing yet; otherwise ask it.
set "DONE=0"
if defined CREATED goto pending
for /f "usebackq delims=" %%R in (`%PSQL% -d %DB% -At -c "SELECT count(*) FROM dbo.SchemaMigration WHERE FileName = '%FILE%';"`) do set "DONE=%%R"
if "%DONE%"=="1" goto :eof

:pending
if defined DRYRUN (
    echo Pending:  %FILE%
    set /a PENDING+=1
    goto :eof
)

echo Applying: %FILE%
REM The file and its record in one transaction: --single-transaction wraps
REM every -f and -c in one BEGIN ... COMMIT, and rolls all of it back on the
REM first error, so either both are committed or neither is.
call :source "%FILE%"
%PSQL% -d %DB% --single-transaction -f "%SRC%" -c "%TRACK% INSERT INTO dbo.SchemaMigration (FileName) VALUES ('%FILE%') ON CONFLICT (FileName) DO NOTHING;"
if errorlevel 1 (
    call :cleanup "%FILE%"
    set "FAILED=%FILE%"
    goto :eof
)
call :cleanup "%FILE%"
set /a APPLIED+=1
goto :eof

REM ----------------------------------------------------------------- :source
REM Where psql reads a file from: the file itself, or a copy inside --docker.
:source
if not defined DOCKER (
    set "SRC=%MIG%\%~1"
    goto :eof
)
set "SRC=/tmp/pos-migration-%~1"
docker cp "%MIG%\%~1" "%DOCKER%:%SRC%" >nul
goto :eof

:cleanup
if defined DOCKER docker exec -u 0 %DOCKER% rm -f "/tmp/pos-migration-%~1" >nul 2>&1
goto :eof

REM ------------------------------------------------------------------ finish
:failed
echo.
echo === FAILED: %FAILED% - the error is above. Nothing after it was run. ===
echo Fix the cause and run this again; files already applied are skipped.
set "RC=1"

:finish
echo.
if defined OLDCP chcp %OLDCP% >nul
if not defined NOPAUSE pause
endlocal & exit /b %RC%
