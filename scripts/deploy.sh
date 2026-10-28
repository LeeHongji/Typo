#!/bin/bash
# Install the same notarized app/DMG produced for a release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-/Applications/Type4Me.app}"
VARIANT="${VARIANT:-pure}"
LAUNCH_APP="${LAUNCH_APP:-1}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "${1:-}" = "--help" ]; then
    cat <<'HELP'
Run from an isolated non-iCloud git worktree containing the intended source:
  APP_VERSION=X.Y.Z VARIANT=pure bash scripts/deploy.sh
  APP_VERSION=X.Y.Z VARIANT=local bash scripts/deploy.sh
Builds and verifies the release app and DMG, then backs up and replaces
/Applications/Type4Me.app. Does not publish to GitHub or reset permissions.
NOTARY_PROFILE uses build-dmg.sh's default. NOTARY_KEYCHAIN optionally selects
a keychain file; otherwise use notarytool's default lookup. LAUNCH_APP=0 skips launch.
HELP
    exit 0
fi
[ "$#" = "0" ] || fail "Unexpected arguments; see --help."
[ "$APP_PATH" = "/Applications/Type4Me.app" ] || fail "Local deployment requires the production app path."
[ ! -L "$APP_PATH" ] || fail "Refusing a symlink at the production app path."
[ "${APP_FLAVOR:-public}" = "public" ] || fail "Local deployment requires the public app identity."
[ "${APP_NAME:-Type4Me}" = "Type4Me" ] || fail "Local deployment requires Type4Me."
[ "${APP_BUNDLE_ID:-com.type4me.app}" = "com.type4me.app" ] || fail "Local deployment requires com.type4me.app."
[ "${TYPE4ME_DEV_BUILD:-0}" = "0" ] || fail "Dev builds cannot use production deployment."
[ "${SKIP_NOTARIZE:-0}" = "0" ] || fail "Local deployment requires app and DMG notarization."
case "$VARIANT" in
    pure|cloud) VARIANT=pure; EXPECTED_ARCH=universal ;;
    local) EXPECTED_ARCH=arm64 ;;
    *) fail "Expected VARIANT=pure or local." ;;
esac
ARCH="${ARCH:-$EXPECTED_ARCH}"
[ "$ARCH" = "$EXPECTED_ARCH" ] || fail "Expected $EXPECTED_ARCH for $VARIANT."
[ -n "${APP_VERSION:-}" ] || fail "Set APP_VERSION from the intended source/version; do not use an old script default."
case "$PROJECT_DIR/" in
    *"/Library/Mobile Documents/"*|*"/Library/CloudStorage/"*) fail "Build in a non-iCloud worktree, not the primary checkout." ;;
esac
[ -f "$PROJECT_DIR/.git" ] || fail "Create an isolated git worktree before deploying."
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null

# Match the production Team and resolve only in the login keychain.
IDENTITIES=$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN")
FINGERPRINTS=$(printf '%s\n' "$IDENTITIES" | awk '/"Developer ID Application:.*\(T98LK79X2K\)"/ {print $2}')
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$FINGERPRINTS" | grep -Fxq "$CODESIGN_IDENTITY" \
        || fail "CODESIGN_IDENTITY must be a production Developer ID fingerprint in the login keychain."
else
    [ "$(printf '%s\n' "$FINGERPRINTS" | awk 'NF {n++} END {print n+0}')" = "1" ] \
        || fail "Expected one production Developer ID in the login keychain; select its fingerprint explicitly if ambiguous."
    CODESIGN_IDENTITY="$FINGERPRINTS"
fi
echo "Using Login Keychain Developer ID fingerprint: $CODESIGN_IDENTITY"

requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
verify_identity() {
    local app="$1" metadata
    codesign --verify --deep --strict "$app"
    [ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = "com.type4me.app" ] \
        || fail "Unexpected bundle ID: $app"
    metadata=$(codesign -dvv "$app" 2>&1)
    printf '%s\n' "$metadata" | grep -q '^Authority=Developer ID Application:' || fail "Missing Developer ID: $app"
    printf '%s\n' "$metadata" | grep -qx 'TeamIdentifier=T98LK79X2K' || fail "Unexpected Team: $app"
    [ -n "$(requirement "$app")" ] || fail "Missing designated requirement: $app"
}
verify_app() {
    local app="$1" architectures resources metal size model
    verify_identity "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
    [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$APP_VERSION" ] \
        || fail "Unexpected app version."
    architectures=$(lipo -archs "$app/Contents/MacOS/Type4Me")
    if [ "$ARCH" = "universal" ]; then
        [ "$architectures" = "x86_64 arm64" ] || [ "$architectures" = "arm64 x86_64" ] || fail "Expected universal app."
    else
        [ "$architectures" = "arm64" ] || fail "Expected arm64 app."
    fi
    resources="$app/Contents/Resources"
    if [ "$VARIANT" = "pure" ]; then
        [ ! -e "$resources/Models" ] && [ ! -e "$resources/qwen3-asr-server-dist" ] \
            && [ ! -e "$app/Contents/MacOS/qwen3-asr-server" ] || fail "Local-model payload in pure app."
    else
        [ -d "$resources/Models" ] && [ -x "$app/Contents/MacOS/qwen3-asr-server" ] \
            && [ -x "$resources/qwen3-asr-server-dist/qwen3-asr-server" ] || fail "Missing local model/server payload."
        for model in sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17 silero_vad Qwen3-ASR; do
            [ -d "$resources/Models/$model" ] || fail "Missing model directory: $model"
        done
        [ -n "$(find "$resources/Models/Qwen3-ASR" -name 'model*.safetensors' -type f -size +0c -print -quit)" ] \
            || fail "Missing Qwen3 model weights."
        [ -f "$resources/qwen3-asr-server-dist/_internal/libmlx.dylib" ] || fail "Missing libmlx.dylib."
        metal="$resources/qwen3-asr-server-dist/_internal/mlx.metallib"
        [ -f "$metal" ] || fail "Missing JIT mlx.metallib."
        size=$(stat -f%z "$metal")
        [ "$size" -ge 1048576 ] && [ "$size" -le 6291456 ] || fail "Unexpected JIT mlx.metallib size."
    fi
}

PREVIOUS_REQUIREMENT=""
if [ -e "$APP_PATH" ]; then
    verify_identity "$APP_PATH"
    PREVIOUS_REQUIREMENT=$(requirement "$APP_PATH")
fi

# Fresh output; the release builder owns variant markers, nested signing,
# notarization and stapling. It never builds directly into /Applications.
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
mkdir -p "$DIST_DIR"
OUTPUT=$(mktemp -d "$DIST_DIR/local-install.XXXXXX")
APP_FLAVOR=public APP_NAME=Type4Me APP_BUNDLE_ID=com.type4me.app URL_SCHEME=type4me \
TYPE4ME_DEV_BUILD=0 SKIP_NOTARIZE=0 CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}" VARIANT="$VARIANT" ARCH="$ARCH" APP_VERSION="$APP_VERSION" \
OUT_DIR="$OUTPUT" DMG_NAME=Type4Me-local-install \
bash "$SCRIPT_DIR/build-dmg.sh"
BUILT_APP="$OUTPUT/Type4Me.app"
DMG="$OUTPUT/Type4Me-local-install-notarized.dmg"
verify_app "$BUILT_APP"
codesign --verify --strict "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type install "$DMG"
hdiutil verify "$DMG"
CURRENT_REQUIREMENT=$(requirement "$BUILT_APP")

check_previous_identity() {
    [ ! -L "$APP_PATH" ] || fail "Production app path became a symlink during build."
    if [ -n "$PREVIOUS_REQUIREMENT" ]; then
        verify_identity "$APP_PATH"
        [ "$(requirement "$APP_PATH")" = "$PREVIOUS_REQUIREMENT" ] || fail "Installed app identity changed during build."
        [ "$CURRENT_REQUIREMENT" = "$PREVIOUS_REQUIREMENT" ] || fail "Designated requirement changed; existing app preserved."
    else
        [ ! -e "$APP_PATH" ] || fail "An app appeared during build; inspect it before replacing."
    fi
}
check_previous_identity

# Stage on the destination filesystem; keep the previous bundle for rollback.
INSTALL_DIR=$(mktemp -d /Applications/.type4me-install.XXXXXX)
CANDIDATE="$INSTALL_DIR/candidate/Type4Me.app"
BACKUP="$INSTALL_DIR/previous/Type4Me.app"
mkdir -p "$(dirname "$CANDIDATE")" "$(dirname "$BACKUP")"
ditto "$BUILT_APP" "$CANDIDATE"
verify_app "$CANDIDATE"
SWAP_STARTED=0
COMPLETED=0
rollback() {
    local status=$?
    trap - EXIT
    if [ "$SWAP_STARTED" = "1" ] && [ "$COMPLETED" = "0" ]; then
        if [ -e "$BACKUP" ]; then
            if [ -e "$APP_PATH" ]; then
                mv "$APP_PATH" "$INSTALL_DIR/failed.app" || exit 1
            fi
            mv "$BACKUP" "$APP_PATH" || exit 1
            echo "Previous app restored: $APP_PATH" >&2
        elif [ -z "$PREVIOUS_REQUIREMENT" ] && [ -e "$APP_PATH" ]; then
            mv "$APP_PATH" "$INSTALL_DIR/failed.app" || exit 1
        fi
    fi
    exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if pgrep -f '^/Applications/Type4Me.app/Contents/MacOS/Type4Me( |$)' >/dev/null; then
    osascript -e 'tell application id "com.type4me.app" to quit'
    for attempt in {1..20}; do
        pgrep -f '^/Applications/Type4Me.app/Contents/MacOS/Type4Me( |$)' >/dev/null || break
        sleep 0.5
    done
    if pgrep -f '^/Applications/Type4Me.app/Contents/MacOS/Type4Me( |$)' >/dev/null; then
        fail "Type4Me has not quit; existing app preserved."
    fi
fi
check_previous_identity
SWAP_STARTED=1
if [ -n "$PREVIOUS_REQUIREMENT" ]; then
    mv "$APP_PATH" "$BACKUP"
fi
mv "$CANDIDATE" "$APP_PATH"
verify_app "$APP_PATH"
[ "$(requirement "$APP_PATH")" = "$CURRENT_REQUIREMENT" ] || fail "Installed signing requirement differs from the verified artifact."
COMPLETED=1
echo "Deployment verified: Developer ID Application | Team T98LK79X2K | $APP_VERSION | $VARIANT | $ARCH"
echo "App: $APP_PATH"
echo "DMG: $DMG"
[ ! -e "$BACKUP" ] || echo "Backup: $BACKUP"
if [ "$LAUNCH_APP" = "1" ]; then
    echo "Launching via GUI session..."
    launchctl asuser "$(id -u)" /usr/bin/open "$APP_PATH"
fi
echo "Done."
