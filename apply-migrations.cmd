@echo off
REM Apply the database migrations in db-migrations\, in order, exactly once each.
REM
REM   apply-migrations.cmd                         Windows login, .\SQLEXPRESS
REM   apply-migrations.cmd -S VMI1342014\SQLEXPRESS
REM   apply-migrations.cmd -S 127.0.0.1,1433 -U sa -P "Root@123"
REM   apply-migrations.cmd --dry-run               list what would run, change nothing
REM   apply-migrations.cmd --dev                   also apply 17-dev-passwords.sql
REM   apply-migrations.cmd --no-pause              for CI or a scheduled task
REM
REM The server and login can also come from POS_SQL_SERVER, POS_SQL_USER and
REM POS_SQL_PASSWORD, which keeps a password off the command line.
REM
REM Why a tracking table: migrations 11-23 use plain CREATE and fail if run a
REM second time, so "run every file" is only safe once. Each file that succeeds
REM is recorded in POSMAIN's dbo.SchemaMigration and skipped from then on.
REM
REM A database that was migrated by hand before this script existed has no
REM tracking table. The first run detects which of 11-23 are already there and
REM records them without running them; 24 onwards are written to be re-run
REM safely, so they are applied (again) once and recorded.
REM
REM 17-dev-passwords.sql gives every demo account the password 1234. It is a
REM development convenience, so it only runs with --dev.

setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

set "MIG=%~dp0db-migrations"
set "SERVER=%POS_SQL_SERVER%"
set "SQLUSER=%POS_SQL_USER%"
set "SQLPASS=%POS_SQL_PASSWORD%"
set "DEV="
set "DRYRUN="
set "NOPAUSE="
set "FRESH="

REM The files that cannot be run twice, each with an object it creates. Used
REM only before tracking starts, to recognise what a database already has.
REM 17, 18, 20 and 21 are not listed: they are safe to run again.
set "MARKERS=(N'nazad-posmain-full.sql', N'core.Company'), (N'11-api-auth-tables.sql', N'core.OtpChallenge'), (N'12-sale-commit.sql', N'sales.usp_CommitSale'), (N'13-registration.sql', N'core.usp_RegisterBusiness'), (N'14-inventory-procs.sql', N'inv.usp_ReceivePurchase'), (N'15-finance-operations.sql', N'core.Notification'), (N'16-periods-payroll.sql', N'fin.usp_OpenBalancePeriod'), (N'19-audit-and-performance.sql', N'audit.AuditEntry'), (N'22-devices.sql', N'device.PosDevice'), (N'23-device-discovery.sql', N'device.DeviceAnnouncement')"

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="-S"         (set "SERVER=%~2"  & shift & shift & goto parse)
if /i "%~1"=="-U"         (set "SQLUSER=%~2" & shift & shift & goto parse)
if /i "%~1"=="-P"         (set "SQLPASS=%~2" & shift & shift & goto parse)
if /i "%~1"=="--dev"      (set "DEV=1"       & shift & goto parse)
if /i "%~1"=="--dry-run"  (set "DRYRUN=1"    & shift & goto parse)
if /i "%~1"=="--no-pause" (set "NOPAUSE=1"   & shift & goto parse)
echo Unknown option: %~1
echo See the comments at the top of this file for usage.
set "RC=2"
goto finish

:parsed
if not defined SERVER set "SERVER=.\SQLEXPRESS"

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

REM ---------------------------------------------------------- fresh install
set "HASDB="
for /f "usebackq delims=" %%R in (`%SQLCMD% -d master -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'POSMAIN') IS NULL THEN 0 ELSE 1 END;"`) do set "HASDB=%%R"

if not "%HASDB%"=="1" (
    if defined DRYRUN (
        echo Pending:  nazad-posmain-full.sql  ^(POSMAIN does not exist yet^)
        echo.
        echo Every numbered migration would follow it.
        set "RC=0"
        goto finish
    )
    echo POSMAIN does not exist. Creating it from nazad-posmain-full.sql...
    set "FRESH=1"
    %SQLCMD% -d master -i "%MIG%\nazad-posmain-full.sql"
    if errorlevel 1 (
        echo.
        echo === FAILED: nazad-posmain-full.sql - the error is above ===
        set "RC=1"
        goto finish
    )
)

REM ------------------------------------------------------- tracking table
REM Created once. On that first run, a database migrated by hand has 11-23
REM recorded by the object each one creates, so they are not run twice.
if defined DRYRUN goto loop

%SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL BEGIN CREATE TABLE dbo.SchemaMigration (FileName NVARCHAR(200) NOT NULL CONSTRAINT PK_SchemaMigration PRIMARY KEY, AppliedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_SchemaMigration_At DEFAULT SYSUTCDATETIME(), AppliedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_SchemaMigration_By DEFAULT SUSER_SNAME(), Baselined BIT NOT NULL CONSTRAINT DF_SchemaMigration_Baselined DEFAULT 0); INSERT INTO dbo.SchemaMigration (FileName, Baselined) SELECT v.FileName, 1 FROM (VALUES %MARKERS%) AS v (FileName, MarkerObject) WHERE OBJECT_ID(v.MarkerObject) IS NOT NULL; DECLARE @n INT = @@ROWCOUNT; PRINT CONCAT(N'Started tracking migrations; ', @n, N' already-applied file(s) recorded without running them.'); END"
if errorlevel 1 (
    echo Could not create the migration tracking table. The error is above.
    set "RC=1"
    goto finish
)

REM Created by this run rather than found, so not a baseline.
if defined FRESH %SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; UPDATE dbo.SchemaMigration SET Baselined = 0 WHERE FileName = N'nazad-posmain-full.sql';" >nul

REM -------------------------------------------------------------- migrations
:loop
set "FAILED="
set "APPLIED=0"
set "PENDING=0"
for /f "delims=" %%F in ('dir /b /a-d /on "%MIG%\*.sql" ^| findstr /r /b /c:"[0-9][0-9]-"') do call :apply "%%F"

echo.
if defined FAILED (
    echo === FAILED: %FAILED% - the error is above. Nothing after it was applied. ===
    echo Fix the cause and run this again; files already applied are skipped.
    set "RC=1"
    goto finish
)

if defined DRYRUN (
    echo %PENDING% migration^(s^) pending.
    set "RC=0"
    goto finish
)

if "%APPLIED%"=="0" (echo The database is up to date.) else (echo Applied %APPLIED% migration^(s^).)

REM Read-only: every line prints PASS or FAIL.
if exist "%MIG%\99-verify-install.sql" (
    echo.
    echo Verifying the install...
    %SQLCMD% -d POSMAIN -i "%MIG%\99-verify-install.sql"
)
set "RC=0"
goto finish

REM ----------------------------------------------------------------- :apply
:apply
if defined FAILED goto :eof
set "FILE=%~1"

REM Diagnostics, not migrations.
if "%FILE:~0,3%"=="00-" goto :eof
if "%FILE:~0,3%"=="99-" goto :eof

if /i "%FILE%"=="17-dev-passwords.sql" if not defined DEV (
    echo Skipped:  %FILE%  ^(demo passwords; pass --dev to apply^)
    goto :eof
)

REM Before tracking starts (a dry run on a database migrated by hand), answer
REM the way the first real run will: present if its marker object exists.
set "DONE=0"
for /f "usebackq delims=" %%R in (`%SQLCMD% -d POSMAIN -h -1 -W -Q "SET NOCOUNT ON; IF OBJECT_ID(N'dbo.SchemaMigration') IS NOT NULL SELECT COUNT(*) FROM dbo.SchemaMigration WHERE FileName = N'%FILE%' ELSE SELECT COUNT(*) FROM (VALUES %MARKERS%) AS v (FileName, MarkerObject) WHERE v.FileName = N'%FILE%' AND OBJECT_ID(v.MarkerObject) IS NOT NULL;"`) do set "DONE=%%R"
if "%DONE%"=="1" goto :eof

if defined DRYRUN (
    echo Pending:  %FILE%
    set /a PENDING+=1
    goto :eof
)

echo Applying: %FILE%
%SQLCMD% -d POSMAIN -i "%MIG%\%FILE%"
if errorlevel 1 (
    set "FAILED=%FILE%"
    goto :eof
)

%SQLCMD% -d POSMAIN -h -1 -Q "SET NOCOUNT ON; INSERT INTO dbo.SchemaMigration (FileName) VALUES (N'%FILE%');" >nul
if errorlevel 1 (
    echo Applied %FILE% but could not record it; it will run again next time.
    set "FAILED=%FILE%"
    goto :eof
)
set /a APPLIED+=1
goto :eof

REM ----------------------------------------------------------------- finish
:finish
echo.
if not defined NOPAUSE pause
endlocal & exit /b %RC%
