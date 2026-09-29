#!/usr/bin/env bash
# Pre-build check: fails with an actionable message when the stable local
# signing identity (ADR 0007) is missing. Called from the Xcode build phase.

set -euo pipefail

NAME="Memorri Local"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  exit 0
fi

echo "error: Code signing identity \"$NAME\" not found in your keychain." >&2
echo "error: Run scripts/create-signing-certificate.sh once on this Mac, then build again." >&2
exit 1
