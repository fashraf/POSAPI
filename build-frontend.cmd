@echo off
REM Build the React app (POSFO) and put it in src\frontend, where the API serves
REM it: one process, one origin, the app at / and the API at /api.
REM
REM   build-frontend.cmd                          build POSFO into src\frontend
REM   build-frontend.cmd --publish C:\deploy\pos  ...then dotnet publish (Release)
REM   build-frontend.cmd --frontend D:\src\POSFO  POSFO somewhere else
REM   build-frontend.cmd --install                run npm ci even if node_modules exists
REM   build-frontend.cmd --no-pause               for CI or a scheduled task
REM
REM The app is built with VITE_API_BASE_URL empty, so it calls /api on whatever
REM server it was loaded from - the API serving it. A .env.local that points at
REM another API does not leak into this build.
REM
REM The previous build in src\frontend is replaced only after the new one
REM succeeds, so a failed build never leaves the API serving nothing.

setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

set "HERE=%~dp0"
set "FRONTEND=%POSFO_PATH%"
if not defined FRONTEND set "FRONTEND=%HERE%..\POSFO"
set "OUT=%HERE%src\frontend"
set "PUBLISH="
set "INSTALL="
set "NOPAUSE="
set "RC=0"

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--frontend" (set "FRONTEND=%~2" & shift & shift & goto parse)
if /i "%~1"=="--publish"  (set "PUBLISH=%~2"  & shift & shift & goto parse)
if /i "%~1"=="--install"  (set "INSTALL=1"    & shift & goto parse)
if /i "%~1"=="--no-pause" (set "NOPAUSE=1"    & shift & goto parse)
echo Unknown option: %~1
echo See the comments at the top of this file for usage.
set "RC=2"
goto finish

:parsed
if not exist "%FRONTEND%\package.json" (
    echo No frontend at %FRONTEND% ^(expected package.json^).
    echo Use --frontend ^<path^> or set POSFO_PATH.
    set "RC=1"
    goto finish
)

where npm >nul 2>&1
if errorlevel 1 (
    echo npm was not found on PATH. Install Node.js and try again.
    set "RC=1"
    goto finish
)

echo.
echo Frontend: %FRONTEND%
echo Output:   %OUT%
echo.

pushd "%FRONTEND%"

set "NEEDINSTALL=%INSTALL%"
if not exist node_modules set "NEEDINSTALL=1"
if defined NEEDINSTALL (
    echo Installing packages...
    if exist package-lock.json (call npm ci) else (call npm install)
    if errorlevel 1 (
        popd
        echo === Installing packages FAILED - the error is above ===
        set "RC=1"
        goto finish
    )
    echo.
)

echo Building...
REM Empty base URL: the app calls /api on the server that served it.
set "VITE_API_BASE_URL="
call npm run build
if errorlevel 1 (
    popd
    echo.
    echo === Build FAILED - the error is above. src\frontend was not changed. ===
    set "RC=1"
    goto finish
)

if not exist dist\index.html (
    popd
    echo The build finished but dist\index.html is missing. Nothing was replaced.
    set "RC=1"
    goto finish
)

REM Swap in the new build. The old one goes only now that the new one exists.
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
xcopy "dist\*" "%OUT%\" /e /i /q /y >nul
if errorlevel 1 (
    popd
    echo Copying the build to %OUT% FAILED.
    set "RC=1"
    goto finish
)
popd

echo.
echo === Frontend built into %OUT% ===

if defined PUBLISH (
    echo.
    echo Publishing the API with the frontend to %PUBLISH%...
    call dotnet publish src\PosApi -c Release -o "%PUBLISH%"
    if errorlevel 1 (
        echo === Publish FAILED - the error is above ===
        set "RC=1"
        goto finish
    )
    echo.
    echo === Published: run it with  dotnet "%PUBLISH%\PosApi.dll" ===
)

echo.
echo Start the API ^(run-api.cmd^) and open its address:
echo the app is at /, the API at /api.

:finish
echo.
if not defined NOPAUSE pause
endlocal & exit /b %RC%
