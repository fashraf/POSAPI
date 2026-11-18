#!/usr/bin/env bash
#
# Validate signed ZATCA invoices with ZATCA's own validator (the .NET SDK's
# fatooraNet), one chain at a time.
#
#   tools/zatca/validate-chain.sh [--pih <88-char value>] <file.xml | folder>...
#
# A folder stands for its *.xml files in name order. The files are one chain,
# in issue order: each is checked against the previous one's hash, the way
# ZATCA checks a real chain. The first is checked against --pih, or the
# genesis value ZATCA ships (Data/PIH/pih.txt) when it is omitted.
#
# Exit 0 when every file passes (warnings allowed), 1 otherwise.
#
# Needs the SDK unpacked once (it is downloaded from sandbox.zatca.gov.sa
# behind a login, so this cannot fetch it). ZATCA_SDK_HOME names its folder;
# by default the one beside POSAPI. .NET 8 runtime only; no Java.
#
# Facts this script rests on (measured 2026-11-18 on the developer kit's
# chains, all of which pass):
#
# - The chain field (PIH) is base64 of the HEX text of the previous
#   invoice's SHA-256 (88 characters). The invoice hash itself is base64 of
#   the raw 32 bytes (44 characters). Feeding the 44-character form fails
#   with KSA-13 "PIH is inValid".
# - The validator checks the signature against the certificate it is given,
#   not the one inside the invoice. Each invoice's own X509Certificate is
#   handed to it, so documents signed by our keys (or the kit's self-signed
#   test certificate) validate; a standard invoice with no signature falls
#   back to the SDK's certificate.
# - Simplified invoices always warn BR-KSA-98 ("submit within 24 hours")
#   once their issue time is in the past. Expected, not a failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${ZATCA_SDK_HOME:-$HERE/../../../zatca-einvoicing-sdk-DotNet-238-R3.4.8}"
CLI="$SDK/Lib/Dot-Net8/Test/fatooraNet.dll"

if [[ ! -f "$CLI" ]]; then
  echo "ZATCA SDK not found at $SDK (set ZATCA_SDK_HOME)." >&2
  exit 2
fi

PIH="$(tr -d '\r\n' < "$SDK/Data/PIH/pih.txt")"
if [[ "${1:-}" == "--pih" ]]; then
  PIH="${2:?--pih needs a value}"
  shift 2
fi
if [[ $# -eq 0 ]]; then
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 64
fi

FILES=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(find "$arg" -maxdepth 1 -name '*.xml' | sort)
  else
    FILES+=("$arg")
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The invoice's own signing certificate, bare base64 like the SDK's cert.pem.
own_certificate() {
  python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<ds:X509Certificate>\s*([A-Za-z0-9+/=\s]+?)\s*</ds:X509Certificate>", text)
print(re.sub(r"\s", "", m.group(1)) if m else "", end="")
PY
}

# base64(raw sha256) -> base64(hex text), the chain field's form.
chain_value() {
  python3 -I -c 'import base64,sys; print(base64.b64encode(base64.b64decode(sys.argv[1]).hex().encode()).decode(), end="")' "$1"
}

FAILED=0
for f in "${FILES[@]}"; do
  printf '%s' "$PIH" > "$WORK/pih.txt"
  CERT="$(own_certificate "$f")"
  if [[ -n "$CERT" ]]; then
    printf '%s' "$CERT" > "$WORK/cert.pem"
  else
    cp "$SDK/Data/Certificates/cert.pem" "$WORK/cert.pem"
  fi

  OUT="$(dotnet "$CLI" validate -invoice "$f" -certificate "$WORK/cert.pem" -pih "$WORK/pih.txt" 2>&1)"
  if grep -q 'Overall status \[Success\]' <<<"$OUT"; then
    echo "PASSED  $f"
  else
    echo "FAILED  $f"
    FAILED=1
  fi
  # Every warning and error except the expected 24-hour one.
  grep -E '\[(warning|Error)\]' <<<"$OUT" | grep -v 'BR-KSA-98' | sed 's/^/        /'

  HASH="$(dotnet "$CLI" generateHash -invoice "$f" 2>&1 | sed -n 's/.*Hash = *\([A-Za-z0-9+/=]\{44\}\).*/\1/p' | tail -1)"
  if [[ -z "$HASH" ]]; then
    echo "        could not hash $f; the rest of the chain is not checked" >&2
    exit 1
  fi
  PIH="$(chain_value "$HASH")"
done

exit $FAILED
