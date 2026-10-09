#!/usr/bin/env bash
# Build the SaaS admin console (POSA) and put it in src/frontend-admin, where
# the API serves it at /admin/ — the console's API is /api/superadmin on the
# same server, so the build needs no API address at all.
#
#   ./build-frontend-admin.sh                         build POSA into src/frontend-admin
#   ./build-frontend-admin.sh --publish ./publish     ...then dotnet publish (Release)
#   ./build-frontend-admin.sh --frontend ../POSA      POSA somewhere else
#   ./build-frontend-admin.sh --install               run npm ci even if node_modules exists
#
# The previous build in src/frontend-admin is replaced only after the new one
# succeeds, so a failed build never leaves the API serving nothing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND="${POSA_PATH:-$HERE/../POSA}"
OUT="$HERE/src/frontend-admin"
PUBLISH=""
INSTALL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --frontend) FRONTEND="${2:-}"; shift 2 ;;
        --publish)  PUBLISH="${2:-}"; shift 2 ;;
        --install)  INSTALL=1; shift ;;
        -h|--help)  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "Unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

if [ ! -f "$FRONTEND/package.json" ]; then
    echo "No frontend at $FRONTEND (expected package.json). Use --frontend <path> or POSA_PATH."
    exit 1
fi
FRONTEND="$(cd "$FRONTEND" && pwd)"

for tool in node npm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool was not found on PATH."; exit 1; }
done

echo
echo "Frontend: $FRONTEND"
echo "Output:   $OUT"
echo

cd "$FRONTEND"

if [ -n "$INSTALL" ] || [ ! -d node_modules ]; then
    echo "Installing packages..."
    if [ -f package-lock.json ]; then npm ci; else npm install; fi
    echo
fi

echo "Building..."
npm run build

if [ ! -f dist/index.html ]; then
    echo "The build finished but dist/index.html is missing. Nothing was replaced."
    exit 1
fi

# Swap in the new build. The old one goes only now that the new one exists.
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R dist/. "$OUT/"

echo
echo "=== Console built: $(find "$OUT" -type f | wc -l | tr -d ' ') files in $OUT ==="

if [ -n "$PUBLISH" ]; then
    echo
    echo "Publishing the API with the frontend to $PUBLISH..."
    cd "$HERE"
    dotnet publish src/PosApi -c Release -o "$PUBLISH"
    echo
    echo "=== Published: run it with  dotnet $PUBLISH/PosApi.dll ==="
fi

echo
echo "Start the API (e.g. dotnet run --project src/PosApi) and open <address>/admin/"
