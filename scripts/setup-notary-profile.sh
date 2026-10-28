#!/bin/bash
set -euo pipefail

PROFILE_NAME="${NOTARY_PROFILE:-selectx-notary}"
TEAM_ID="${APPLE_TEAM_ID:-T98LK79X2K}"

cat <<INFO
This creates or replaces the shared Apple notarization profile in your login keychain.

Before continuing, generate an Apple app-specific password at:
https://account.apple.com/account/manage/section/security

The password is requested by notarytool using a secure terminal prompt. It is
stored in Keychain and is never written to this script or the build logs.
INFO

if [ -z "${APPLE_ID:-}" ]; then
    read -r -p "Apple ID: " APPLE_ID
fi

if [ -z "$APPLE_ID" ]; then
    echo "ERROR: Apple ID cannot be empty."
    exit 1
fi

xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --validate

echo "Validating notarization profile '$PROFILE_NAME'..."
xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null
echo "Notarization profile '$PROFILE_NAME' is ready in the login keychain."
