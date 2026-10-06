@echo off
REM Start the API and keep the window open whatever happens.
REM
REM `dotnet run` on its own closes the window the moment the process exits, so a
REM startup failure vanishes before it can be read. The pause at the end is the
REM whole point of this file.

cd /d "%~dp0"

echo.
echo Starting Nazad POS API...
echo.

REM Do NOT pass --environment here. It is not a `dotnet run` option; the SDK
REM treats it as an unrecognised argument and exits immediately, which is what
REM makes it look as though the app started and died. The environment comes from
REM launchSettings.json instead.
dotnet run --project src\PosApi --urls="http://0.0.0.0:5001"

echo.
echo === The API has stopped. Exit code: %ERRORLEVEL% ===
echo.
echo If this closed straight after "Building...", the message above says why.
echo.
pause
