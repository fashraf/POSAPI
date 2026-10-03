@echo off
REM Create or update the POSMAIN database from db-migrations\.
REM
REM   apply-migrations.cmd                          Windows login, .\SQLEXPRESS
REM   apply-migrations.cmd -S VMI1342014\SQLEXPRESS
REM   apply-migrations.cmd -S 127.0.0.1,1433 -U sa -P "Root@123"
REM
REM   --dry-run    list what would run; change nothing
REM   --demo       also load 900-demo-data.sql (demo company, users with
REM                password 1234). Only on a database this run creates.
REM   --adopt      take over a database built by the old migration files
REM                (11-43): record 001 and 002 as already applied
REM   --recreate   DROP POSMAIN and build it again from scratch
REM   --yes        do not ask before --recreate drops the database
REM   --no-pause   for CI or a scheduled task
REM
REM The server and login can also come from POS_SQL_SERVER, POS_SQL_USER and
REM POS_SQL_PASSWORD, which keeps a password off the command line.
REM
REM Files, in name order:
REM   001-899  migrations. Each runs once and is recorded in dbo.SchemaMigration.
REM            001 is the whole schema, 002 the reference data; a later change
REM            is a new file numbered after the last one.
REM   900-998  optional data, run only with --demo on a new database.
REM   999      read-only health check, run after every apply.

setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

set "MIG=%~dp0db-migrations"
set "SERVER=%POS_SQL_SERVER%"
set "SQLUSER=%POS_SQL_USER%"
set "SQLPASS=%POS_SQL_PASSWORD%"
set "DEMO="
set "DRYRUN="
set "ADOPT="
set "RECREATE="
set "YES="
set "NOPAUSE="
set "CREATED="
set "ADOPTING="
set "RC=0"

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="-S"         (set "SERVER=%~2"  & shift & shift & goto parse)
if /i "%~1"=="-U"         (set "SQLUSER=%~2" & shift & shift & goto parse)
if /i "%~1"=="-P"         (set "SQLPASS=%~2" & shift & shift & goto parse)
if /i "%~1"=="--demo"     (set "DEMO=1"      & shift & goto parse)
if /i "%~1"=="--dry-run"  (set "DRYRUN=1"    & shift & goto parse)
if /i "%~1"=="--adopt"    (set "ADOPT=1"     & shift & goto parse)
if /i "%~1"=="--recreate" (set "RECREATE=1"  & shift & goto parse)
if /i "%~1"=="--yes"      (set "YES=1"       & shift & goto parse)
if /i "%~1"=="--no-pause" (set "NOPAUSE=1"   & shift & goto parse)
echo Unknown option: %~1
echo See the comments at the top of this file for usage.
set "RC=2"
goto finish

:parsed
if not defined SERVER set "SERVER=.\SQLEXPRESS"
if defined ADOPT if defined RECREATE (
    echo --adopt keeps the database and --recreate drops it. Choose one.
    set "RC=2"
    goto finish
)

REM -E is a Windows login. With a SQL login the password goes in SQLCMDPASSWORD
REM rather than -P, so it does not show up in the process list.
if defined SQLUSER (
    set "AUTH=-U "%SQLUSER%""
    set "SQLCMDPASSWORD=%SQLPASS%"
) else (
    set "AUTH=-E"
)

REM -b  stop and fail on the first error
REM -I  QUOTED_IDENTIFIER ON; filtered indexes fail without it
REM -C  trust the server certificate (local SQL Express has a self-signed one)
REM -f  read the files as UTF-8, or every Arabic string is stored garbled
set "SQLCMD=sqlcmd -S "%SERVER%" %AUTH% -b -I -C -f 65001"

where sqlcmd >nul 2>&1
if errorlevel 1 (
    echo sqlcmd was not found on PATH.
    echo Install "sqlcmd" from Microsoft ^(SQL Server command line tools^) and try again.
    set "RC=1"
    goto finish
)

echo.
echo Server:     %SERVER%
if defined SQLUSER (echo Login:      %SQLUSER%) else (echo Login:      Windows authentication)
echo Migrations: %MIG%
if defined DRYRUN echo Mode:       dry run - nothing will be changed
echo.

%SQLCMD% -d master -h -1 -Q "SET NOCOUNT ON; SELECT 1;" >nul
if errorlevel 1 (
    echo Could not connect to %SERVER%. The error is above.
    set "RC=1"
    goto finish
)

REM -------------------------------------------------------------- what is there
REM missing  no POSMAIN database
REM empty    POSMAIN exists with no schema
REM tracked  built from 001 by this script
REM legacy   built by the old migration files, before 001 existed
:detect
set "STATE="
for /f "usebackq delims=" %%R in (`%SQLCMD% -d master -h -1 -W -Q "SET NOCOUNT ON; IF DB_ID(N'POSMAIN') IS NULL SELECT N'missing' ELSE EXEC (N'USE POSMAIN; IF OBJECT_ID(N''dbo.SchemaMigration'') IS NULL SELECT CASE WHEN SCHEMA_ID(N''core'') IS NULL THEN N''empty'' ELSE N''legacy'' END ELSE SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE FileName = N''001-baseline-schema.sql'') THEN N''tracked'' WHEN SCHEMA_ID(N''core'') IS NULL THEN N''empty'' ELSE N''legacy'' END');"`) do set "STATE=%%R"

if not defined STATE (
    echo Could not tell what state POSMAIN is in. The error is above.
    set "RC=1"
    goto finish
)
echo Database:   POSMAIN is %STATE%
echo.

if defined RECREATE if not "%STATE%"=="missing" goto recreate
if "%STATE%"=="legacy" goto legacy
if "%STATE%"=="missing" set "CREATED=1"
if "%STATE%"=="empty" set "CREATED=1"
if defined DEMO if not defined CREATED (
    echo --demo only loads into a database this run creates. POSMAIN already
    echo exists; add --recreate to rebuild it with the demo data.
    set "RC=2"
    goto finish
)
goto migrate

REM ------------------------------------------------------------------ legacy
:legacy
if defined ADOPT goto adopt
echo POSMAIN was built by the old migration files ^(11-43^), which 001 and 002
echo replaced. Choose one:
echo.
echo   --adopt     the database has every old migration applied ^(through 43^).
echo               Its schema already matches 001; it is recorded as such.
echo   --recreate  DROP the database and build it again. Use this when an old
echo               migration failed part-way, or the data is only test data.
set "RC=1"
goto finish

:adopt
REM Adopting is only honest if the schema really is the final one. The two
REM newest old migrations each left a parameter only they add.
set "FINAL="
for /f "usebackq delims=" %%R in (`%SQLCMD% -d POSMAIN -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'sales.usp_CommitSale')) LIKE N'%%@CashDueH%%' AND OBJECT_DEFINITION(OBJECT_ID(N'core.usp_RegisterBusiness')) LIKE N'%%@PasswordHash%%' AND COL_LENGTH(N'sales.Sale', N'OrderType') IS NOT NULL THEN 1 ELSE 0 END;"`) do set "FINAL=%%R"
if not "%FINAL%"=="1" (
    echo Cannot adopt: this database stopped before the last old migration
    echo ^(42 or 43 is missing^), so its schema does not match 001.
    echo Use --recreate to rebuild it.
    set "RC=1"
    goto finish
)
if defined DRYRUN (
    echo Would record 001 and 002 as already applied.
    set "ADOPTING=1"
    goto migrate
)
call :ensure_tracking
if defined FAILED goto failed
%SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; INSERT INTO dbo.SchemaMigration (FileName, Baselined) SELECT v.f, 1 FROM (VALUES (N'001-baseline-schema.sql'), (N'002-reference-data.sql')) AS v (f) WHERE NOT EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE FileName = v.f);" >nul
if errorlevel 1 (
    set "FAILED=recording the adoption"
    goto failed
)
echo Adopted: 001 and 002 recorded as already applied.
echo.
goto migrate

REM ---------------------------------------------------------------- recreate
:recreate
set "SALES=0"
for /f "usebackq delims=" %%R in (`%SQLCMD% -d POSMAIN -h -1 -W -Q "SET NOCOUNT ON; IF OBJECT_ID(N'sales.Sale') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM sales.Sale;"`) do set "SALES=%%R"
if defined DRYRUN (
    echo Would DROP POSMAIN ^(%SALES% sale^(s^) in it^) and build it again.
    set "STATE=missing"
    set "CREATED=1"
    goto migrate
)
echo --recreate will DROP the POSMAIN database on %SERVER%.
echo It holds %SALES% sale^(s^). Everything in it is deleted.
if defined YES goto drop
set "CONFIRM="
set /p "CONFIRM=Type POSMAIN to confirm: "
if not "%CONFIRM%"=="POSMAIN" (
    echo Not confirmed. Nothing was changed.
    set "RC=1"
    goto finish
)

:drop
%SQLCMD% -d master -h -1 -Q "SET NOCOUNT ON; ALTER DATABASE POSMAIN SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE POSMAIN;"
if errorlevel 1 (
    set "FAILED=dropping POSMAIN"
    goto failed
)
echo POSMAIN dropped.
echo.
set "STATE=missing"
set "CREATED=1"
goto migrate

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

if exist "%MIG%\999-verify-install.sql" (
    echo.
    echo Verifying the install...
    %SQLCMD% -d POSMAIN -i "%MIG%\999-verify-install.sql"
)
goto finish

REM ------------------------------------------------------------------ :apply
:apply
if defined FAILED goto :eof
set "FILE=%~1"
set "PREFIX=%FILE:~0,3%"

REM 999 is the health check, run once at the end.
if "%PREFIX%"=="999" goto :eof

REM A dry run of --adopt: these two would be recorded, not run.
if defined ADOPTING if "%PREFIX%"=="001" goto :eof
if defined ADOPTING if "%PREFIX%"=="002" goto :eof

REM 900-998: optional data, only into a database this run created.
if "%PREFIX:~0,1%"=="9" (
    if not defined DEMO goto :eof
    if not defined CREATED goto :eof
)

set "DONE=0"
if defined CREATED if defined DRYRUN goto pending
for /f "usebackq delims=" %%R in (`%SQLCMD% -d POSMAIN -h -1 -W -Q "SET NOCOUNT ON; IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.SchemaMigration WHERE FileName = N'%FILE%';"`) do set "DONE=%%R"
if "%DONE%"=="1" goto :eof

:pending
if defined DRYRUN (
    echo Pending:  %FILE%
    set /a PENDING+=1
    goto :eof
)

echo Applying: %FILE%
REM From master: 001 creates POSMAIN itself, and every file says USE POSMAIN.
%SQLCMD% -d master -i "%MIG%\%FILE%"
if errorlevel 1 (
    set "FAILED=%FILE%"
    goto :eof
)

call :ensure_tracking
if defined FAILED goto :eof
%SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; INSERT INTO dbo.SchemaMigration (FileName) VALUES (N'%FILE%');" >nul
if errorlevel 1 (
    echo Applied %FILE% but could not record it.
    set "FAILED=%FILE%"
    goto :eof
)
set /a APPLIED+=1
goto :eof

REM --------------------------------------------------------- :ensure_tracking
:ensure_tracking
%SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL CREATE TABLE dbo.SchemaMigration (FileName NVARCHAR(200) NOT NULL CONSTRAINT PK_SchemaMigration PRIMARY KEY, AppliedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_SchemaMigration_At DEFAULT SYSUTCDATETIME(), AppliedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_SchemaMigration_By DEFAULT SUSER_SNAME(), Baselined BIT NOT NULL CONSTRAINT DF_SchemaMigration_Baselined DEFAULT 0);" >nul
if errorlevel 1 set "FAILED=creating dbo.SchemaMigration"
goto :eof

REM ------------------------------------------------------------------ finish
:failed
echo.
echo === FAILED: %FAILED% - the error is above. Nothing after it was run. ===
echo Fix the cause and run this again; files already applied are skipped.
set "RC=1"

:finish
echo.
if not defined NOPAUSE pause
endlocal & exit /b %RC%
