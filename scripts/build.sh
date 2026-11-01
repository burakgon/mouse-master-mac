#!/bin/bash
# Builds "Mouse Master.app" into ./build, with the agent and mmctl inside, and signs it.
#
#   scripts/build.sh                 release build for this Mac's architecture
#   ARCHS="arm64 x86_64" scripts/build.sh    universal build
#   CODESIGN_IDENTITY=- scripts/build.sh     ad-hoc signature
#
# Releases are built by scripts/release.sh, which also notarizes them.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
# Fixed per version: a changing Info.plist changes the ad-hoc signature, and macOS ties
# the Accessibility and Input Monitoring permissions to it.
BUILD_NUMBER=${BUILD_NUMBER:-$VERSION}
ARCHS=${ARCHS:-$(uname -m)}
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

# The signature decides whether macOS treats a new build as the same app. With a Developer
# ID certificate (a team ID) it keeps the Accessibility and Input Monitoring permissions
# and launchd starts the new agent straight away. Without one, every build is a stranger:
# launchd kills its first start ("Launch Constraint Violation") until it is registered again.
#
# Signed with the first of: CODESIGN_IDENTITY (a certificate name or SHA-1, or - for ad
# hoc), a "Developer ID Application" certificate in the keychain, the local identity that
# scripts/make-signing-identity.sh creates, ad hoc. A certificate must not be expired or
# revoked, or macOS treats the app as malware.

# The SHA-1 of the valid Developer ID identity that expires last: a team can have several
# certificates with the same name, and codesign refuses a name that matches two.
developer_id() {
    local certs hash end best="" best_end=-1
    certs=$(security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null) || return 0
    for hash in $(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p'); do
        end=$(awk -v h="$hash" '$0 == "SHA-1 hash: " h { on = 1; next } on { print } on && /END CERTIFICATE/ { exit }' <<< "$certs" \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        end=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)
        if (( end > best_end )); then best=$hash; best_end=$end; fi
    done
    echo "$best"
}

KEYCHAIN_ARGS=()
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY=$(developer_id)
    if [[ -n "$CODESIGN_IDENTITY" ]]; then
        :
    elif KEYCHAIN=$(scripts/make-signing-identity.sh 2>/dev/null | tail -1) && [[ -f "$KEYCHAIN" ]]; then
        security unlock-keychain -p "$(cat "$HOME/Library/Application Support/Mouse Master/Signing/keychain-password")" "$KEYCHAIN"
        CODESIGN_IDENTITY="Mouse Master Local Signing"
        KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
    else
        CODESIGN_IDENTITY=-
    fi
fi
SIGNER=$CODESIGN_IDENTITY
if [[ "$CODESIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    SIGNER=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/.*$CODESIGN_IDENTITY \"\(.*\)\".*/\1/p" | head -1)
fi

echo "==> Building Mouse Master $VERSION ($BUILD_NUMBER) for $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}" --product MouseMaster
swift build -c release "${ARCH_FLAGS[@]}" --product mmctl
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

APP="build/Mouse Master.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Helpers"

ICON=build/AppIcon.icns
if [[ ! -f $ICON || Resources/Artwork/AppIcon.svg -nt $ICON || scripts/make-icon.swift -nt $ICON ]]; then
    echo "==> Rendering the icon"
    mkdir -p build
    swift scripts/make-icon.swift Resources/Artwork/AppIcon.svg "$ICON"
fi

plist() {
    sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$1" > "$2"
}

plist Resources/Bundle/App-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/Bundle/com.burakgon.MouseMaster.Agent.plist "$APP/Contents/Library/LaunchAgents/"
cp "$BIN/MouseMaster" "$APP/Contents/MacOS/Mouse Master"
cp "$BIN/mmctl" "$APP/Contents/Helpers/mmctl"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Artwork/*.svg "$APP/Contents/Resources/"

echo "==> Signing with: $SIGNER"
# Notarization needs a secure timestamp; other signatures skip it (it needs the network).
TIMESTAMP=--timestamp=none
[[ "$SIGNER" == "Developer ID"* ]] && TIMESTAMP=--timestamp
SIGN=(codesign --force --options runtime "$TIMESTAMP" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$CODESIGN_IDENTITY")
"${SIGN[@]}" --identifier com.burakgon.MouseMaster.mmctl "$APP/Contents/Helpers/mmctl"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Built $APP ($(du -sh "$APP" | cut -f1))"
