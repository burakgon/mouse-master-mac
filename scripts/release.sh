#!/bin/bash
# Builds a release: universal, signed with Developer ID, notarized and stapled, zipped into
# build/release. With --publish it also creates the GitHub release vVERSION, with the
# CHANGELOG entry as its notes; every installed copy then offers it as an update.
#
#   scripts/release.sh             build, notarize and zip
#   scripts/release.sh --publish   ...and publish (needs gh and the commit pushed)
#
# Usually GitHub Actions runs this when a tag is pushed (.github/workflows/release.yml):
#
#   echo 1.2.0 > VERSION   # and a "## 1.2.0" section in CHANGELOG.md
#   git commit -am "Mouse Master 1.2.0" && git tag v1.2.0 && git push origin main v1.2.0
#
# Notarization credentials, the first that is set:
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key (CI)
#   NOTARY_APPLE_ID + NOTARY_PASSWORD                    Apple ID, app-specific password
#   NOTARY_PROFILE (default macos-notary)                notarytool keychain profile
# SKIP_NOTARIZATION=1 skips it, for trying the build only; such a build is never published.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
TAG="v$VERSION"
TEAM_ID=${TEAM_ID:-QCB78CL77T}
APP="build/Mouse Master.app"
OUT=build/release
# A fixed name, so .../releases/latest/download/Mouse-Master.zip always works.
ZIP="$OUT/Mouse-Master.zip"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

fail() { echo "!! $*" >&2; exit 1; }

# The release notes: this version's section of the changelog.
NOTES=$(awk -v v="$VERSION" '
    index($0, "## " v) == 1 || index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## / { exit }
    on { print }' CHANGELOG.md | sed -e '/./,$!d')
[[ -n "$NOTES" ]] || fail "CHANGELOG.md has no \"## $VERSION\" section"

if [[ $PUBLISH == 1 ]]; then
    command -v gh >/dev/null || fail "publishing needs the GitHub CLI (gh)"
    if gh release view "$TAG" >/dev/null 2>&1; then fail "$TAG is already published"; fi
    git diff --quiet HEAD -- Sources Resources Package.swift VERSION || fail "commit your changes first"
fi

echo "==> Building Mouse Master $VERSION"
# build.sh signs with the newest Developer ID certificate in the keychain (or CODESIGN_IDENTITY).
ARCHS=${ARCHS:-"arm64 x86_64"} scripts/build.sh

SIGNED_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$SIGNED_TEAM" == "$TEAM_ID" ]] || fail "signed by team '$SIGNED_TEAM', not $TEAM_ID: is the Developer ID certificate in the keychain?"

rm -rf "$OUT"
mkdir -p "$OUT"
if [[ "${SKIP_NOTARIZATION:-}" == 1 ]]; then
    [[ $PUBLISH == 0 ]] || fail "a build that is not notarized is never published"
    echo "==> Not notarizing (SKIP_NOTARIZATION=1)"
else
    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
    elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
        AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "${NOTARY_PASSWORD:?}" --team-id "$TEAM_ID")
    else
        AUTH=(--keychain-profile "${NOTARY_PROFILE:-macos-notary}")
    fi
    echo "==> Notarizing (a few minutes)"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    xcrun notarytool submit "$OUT/notarize.zip" "${AUTH[@]}" --wait --timeout 45m \
        --output-format json > "$OUT/notary.json" || true
    field() { /usr/bin/plutil -extract "$1" raw -o - "$OUT/notary.json" 2>/dev/null || true; }
    if [[ "$(field status)" != Accepted ]]; then
        cat "$OUT/notary.json" >&2 || true
        [[ -n "$(field id)" ]] && xcrun notarytool log "$(field id)" "${AUTH[@]}" >&2 || true
        fail "notarization failed"
    fi
    rm "$OUT/notarize.zip" "$OUT/notary.json"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
printf '%s\n' "$NOTES" > "$OUT/notes.md"
echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"

if [[ $PUBLISH == 1 ]]; then
    echo "==> Publishing $TAG"
    gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Mouse Master $VERSION" \
        --notes-file "$OUT/notes.md" --target "$(git rev-parse HEAD)"
fi
