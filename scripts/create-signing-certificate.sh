#!/usr/bin/env bash
# Creates the stable self-signed "Memorri Local" code-signing identity used for
# local builds (ADR 0007). Run once per developer machine. Idempotent.
#
# A stable identity keeps macOS Screen Recording permission across rebuilds.
# Usage: scripts/create-signing-certificate.sh [--force]

set -euo pipefail

NAME="Memorri Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=3650
# Use LibreSSL: OpenSSL 3 writes PKCS#12 files that `security import` may reject.
OPENSSL=/usr/bin/openssl

has_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""
}

if [[ "${1:-}" != "--force" ]] && has_identity; then
  echo "Signing identity \"$NAME\" already exists and is valid. Nothing to do."
  echo "Use --force to create a new one."
  exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
P12_PASS="$(uuidgen)"

echo "Generating certificate \"$NAME\" (valid $DAYS days)..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/memorri.p12" -passout "pass:$P12_PASS"

echo "Importing into the login keychain..."
security import "$WORKDIR/memorri.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign

echo "Trusting the certificate for code signing (asks for your login password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

echo
if has_identity; then
  echo "Done. Verify with: security find-identity -v -p codesigning"
  echo "If Memorri was already granted Screen Recording with a different signature,"
  echo "remove it in System Settings > Privacy & Security > Screen Recording and grant it again."
else
  echo "The identity was imported but is not listed as valid." >&2
  echo "Open Keychain Access, set \"$NAME\" > Trust > Code Signing to Always Trust, then re-run." >&2
  exit 1
fi
