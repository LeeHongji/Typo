#!/bin/bash
set -euo pipefail

LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"

has_apple_development_identity() {
    security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
        | grep -Fq '"Apple Development:'
}

if has_apple_development_identity; then
    echo "Apple Development signing identity already exists."
    exit 0
fi

PERSONAL_TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [ -z "$PERSONAL_TEAM_ID" ]; then
    PERSONAL_TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | awk '/teamID =/ { gsub(/[;\"]/ , "", $3); print $3; exit }' || true)
fi
if [ -n "$PERSONAL_TEAM_ID" ] && command -v xcodebuild >/dev/null 2>&1; then
    echo "Requesting an Apple Development certificate for team $PERSONAL_TEAM_ID..."
    if (cd "$PROJECT_DIR" && xcodebuild \
        -scheme Type4Me \
        -destination 'platform=macOS,arch=arm64' \
        -configuration Debug \
        DEVELOPMENT_TEAM="$PERSONAL_TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY='Apple Development' \
        -allowProvisioningUpdates build 2>&1 \
        | grep -E 'Signing Identity:|BUILD (SUCCEEDED|FAILED)|error:'); then
        if has_apple_development_identity; then
            echo "Created Apple Development signing identity."
            exit 0
        fi
    fi
fi

cat >&2 <<'MSG'
ERROR: No Apple Development identity is available.

Open Xcode > Settings > Apple Accounts, sign in to an Apple Account, then run
this script again. An Apple Development identity is required for Keychain
permissions to persist securely across changing Dev binaries.
MSG
exit 1
