@echo off
REM Force a genuinely clean rebuild, then report what was produced.
REM
REM `dotnet run` reuses cached binaries. If a source edit does not change an
REM output timestamp, you can edit a file, run, and still execute yesterday's
REM code -- which is how a fix that is already written appears not to work.

cd /d "%~dp0"

echo.
echo Removing build output...
if exist src\PosApi\bin rmdir /s /q src\PosApi\bin
if exist src\PosApi\obj rmdir /s /q src\PosApi\obj

echo.
echo Restoring...
call dotnet restore
if errorlevel 1 goto failed

echo.
echo Building...
call dotnet build --no-incremental
if errorlevel 1 goto failed

echo.
echo === Built ===
for %%F in (src\PosApi\bin\Debug\net8.0\PosApi.dll) do echo   %%~tF  %%~fF
echo.
echo Compare that timestamp with the "Build compiled at" line the API prints
echo on startup. If they differ, something is still running an older copy.
echo.

call dotnet run --project src\PosApi --no-build
goto end

:failed
echo.
echo === BUILD FAILED - the error is above ===
echo.

:end
pause
