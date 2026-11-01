#!/bin/bash
# Stores the Developer ID certificate as the secrets the Release workflow signs with,
# DEVELOPER_ID_P12_BASE64 and DEVELOPER_ID_P12_PASSWORD, then starts a test run of the
# workflow. Run it once, and again after renewing the certificate.
#
#   scripts/add-signing-secrets.sh [SHA-1]   the Developer ID certificate that expires last
#   DRY_RUN=1 scripts/add-signing-secrets.sh  check everything, set nothing
#
# macOS asks to allow exporting the key: enter your Mac password and click Allow. The export
# gets a new random password, which only the secret keeps.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
HASH=${1:-$(scripts/developer-id.sh)}
[[ -n "$HASH" ]] || { echo "!! no Developer ID Application certificate in the keychain" >&2; exit 1; }
umask 077
T=$(mktemp -d)
trap 'security delete-keychain "$T/check.keychain-db" 2>/dev/null || true; rm -rf "$T"' EXIT

# `security export` exports every identity in a keychain; this exports one.
cat > "$T/export.swift" <<'SWIFT'
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!! \(message)\n".utf8))
    exit(1)
}
let wanted = CommandLine.arguments[1].uppercased()
let passphrase = (ProcessInfo.processInfo.environment["P12_PASSPHRASE"] ?? "") as CFString
let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
var found: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
      let identities = found as? [SecIdentity] else { fail("no identities in the keychain") }
let identity = identities.first { identity in
    var cert: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return false }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data)
    return digest.map { String(format: "%02X", $0) }.joined() == wanted
}
guard let identity else { fail("no identity \(wanted) in the keychain") }
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
params.passphrase = Unmanaged.passUnretained(passphrase as CFTypeRef)
var data: CFData?
let status = SecItemExport(identity, .formatPKCS12, [], &params, &data)
guard status == errSecSuccess, let data else { fail("export failed (\(status))") }
do { try (data as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[2])) } catch { fail("\(error)") }
SWIFT
swiftc -O -o "$T/export-identity" "$T/export.swift"

export P12_PASSPHRASE NEW_PASSWORD
P12_PASSPHRASE=$(openssl rand -hex 16)
echo "==> Exporting certificate $HASH: allow it in the macOS dialog"
"$T/export-identity" "$HASH" "$T/exported.p12"

pem() { openssl pkcs12 -in "$T/exported.p12" -passin env:P12_PASSPHRASE "$@" 2>/dev/null; }
pem -clcerts -nokeys -out "$T/leaf.pem"
pem -nocerts -nodes -out "$T/key.pem"
NAME=$(openssl x509 -in "$T/leaf.pem" -noout -subject | sed -n 's/.*CN=\([^/]*\).*/\1/p')
# The issuing Developer ID intermediate, so the CI keychain can build the chain.
CHAIN=()
ISSUER_URL=$(openssl x509 -in "$T/leaf.pem" -noout -text | sed -n 's/.*CA Issuers - URI:\(http[^ ]*\).*/\1/p' | head -1)
if [[ -n "$ISSUER_URL" ]]; then
    curl -fsSL "${ISSUER_URL/#http:/https:}" -o "$T/issuer.der" || curl -fsSL "$ISSUER_URL" -o "$T/issuer.der"
    openssl x509 -inform DER -in "$T/issuer.der" -out "$T/issuer.pem"
    CHAIN=(-certfile "$T/issuer.pem")
fi
NEW_PASSWORD=$(openssl rand -base64 24)
openssl pkcs12 -export -in "$T/leaf.pem" -inkey "$T/key.pem" ${CHAIN[@]+"${CHAIN[@]}"} -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -passout env:NEW_PASSWORD -out "$T/developer-id.p12"
rm -f "$T/key.pem" "$T/exported.p12"

echo "==> Checking that it imports and signs"
security create-keychain -p check "$T/check.keychain-db"
security unlock-keychain -p check "$T/check.keychain-db"
security import "$T/developer-id.p12" -k "$T/check.keychain-db" -f pkcs12 -P "$NEW_PASSWORD" \
    -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k check "$T/check.keychain-db" > /dev/null
cp /usr/bin/true "$T/probe"
codesign -f -s "$HASH" --keychain "$T/check.keychain-db" --timestamp=none "$T/probe"
echo "    $NAME"

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "==> Dry run: no secrets set"
    exit 0
fi
echo "==> Setting the secrets of $REPO"
base64 -i "$T/developer-id.p12" | gh secret set DEVELOPER_ID_P12_BASE64 -R "$REPO"
printf '%s' "$NEW_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD -R "$REPO"
echo "==> Test run of the Release workflow: it builds and notarizes, and publishes nothing"
gh workflow run release.yml -R "$REPO" --ref main
echo "    https://github.com/$REPO/actions/workflows/release.yml"
