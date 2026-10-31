#!/bin/bash
# Builds "Mouse Master.app" into ./build, with the agent and mmctl inside, and signs it.
#
#   scripts/build.sh                 release build for this Mac's architecture
#   ARCHS="arm64 x86_64" scripts/build.sh    universal build
#   CODESIGN_IDENTITY=- scripts/build.sh     ad-hoc signature
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
# Fixed per version: a changing Info.plist changes the ad-hoc signature, and macOS ties
# the Accessibility and Input Monitoring permissions to it.
BUILD_NUMBER=${BUILD_NUMBER:-$VERSION}
ARCHS=${ARCHS:-$(uname -m)}
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

# Ad-hoc signing by default: locally built apps run without a developer certificate.
# Set CODESIGN_IDENTITY to sign with a certificate (it must not be expired or revoked,
# or macOS treats the app as malware).
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}

echo "==> Building Mouse Master $VERSION ($BUILD_NUMBER) for $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}" --product MouseMaster
swift build -c release "${ARCH_FLAGS[@]}" --product MouseMasterAgent
swift build -c release "${ARCH_FLAGS[@]}" --product mmctl
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

APP="build/Mouse Master.app"
AGENT="$APP/Contents/Library/LoginItems/MouseMasterAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Helpers" \
         "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"

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
plist Resources/Bundle/Agent-Info.plist "$AGENT/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
printf 'APPL????' > "$AGENT/Contents/PkgInfo"
cp Resources/Bundle/com.burakgon.MouseMaster.Agent.plist "$APP/Contents/Library/LaunchAgents/"
cp "$BIN/MouseMaster" "$APP/Contents/MacOS/Mouse Master"
cp "$BIN/MouseMasterAgent" "$AGENT/Contents/MacOS/MouseMasterAgent"
cp "$BIN/mmctl" "$APP/Contents/Helpers/mmctl"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON" "$AGENT/Contents/Resources/AppIcon.icns"
cp Resources/Artwork/*.svg "$APP/Contents/Resources/"

echo "==> Signing with: $CODESIGN_IDENTITY"
SIGN=(codesign --force --options runtime --timestamp=none --sign "$CODESIGN_IDENTITY")
"${SIGN[@]}" --identifier com.burakgon.MouseMaster.mmctl "$APP/Contents/Helpers/mmctl"
"${SIGN[@]}" "$AGENT"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Built $APP ($(du -sh "$APP" | cut -f1))"
