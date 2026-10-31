#!/bin/bash
# Creates a local code signing identity, "Mouse Master Local Signing", in a keychain of its
# own. Builds signed with it keep macOS permissions (Input Monitoring, Accessibility) across
# updates: macOS ties them to this certificate instead of to each build's hash.
#
# The identity never leaves this Mac and is only good for signing; it is not trusted for
# anything else. Run again to print where it is; --delete removes it.
set -euo pipefail

NAME="Mouse Master Local Signing"
DIR="$HOME/Library/Application Support/Mouse Master/Signing"
KEYCHAIN="$HOME/Library/Keychains/mouse-master-signing.keychain-db"
PASSFILE="$DIR/keychain-password"

if [[ "${1:-}" == "--delete" ]]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -rf "$DIR"
    echo "Deleted the $NAME identity."
    exit 0
fi

if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
    echo "$KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=$(openssl rand -hex 16)
printf '%s' "$PASS" > "$PASSFILE"
P12PASS=$(openssl rand -hex 12)

cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$P12PASS" 2>/dev/null

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # never locks by itself
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null 2>&1
echo "Created the $NAME identity in $KEYCHAIN" >&2
echo "$KEYCHAIN"
