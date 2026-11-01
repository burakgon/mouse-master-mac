#!/bin/bash
# Prints the SHA-1 of the valid "Developer ID Application" identity in the keychain that
# expires last, or nothing. A team can have several of these certificates, all with the same
# name, and codesign refuses a name that matches two.
set -euo pipefail
certs=$(security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null) || exit 0
best="" best_end=-1
for hash in $(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p'); do
    end=$(awk -v h="$hash" '$0 == "SHA-1 hash: " h { on = 1; next } on { print } on && /END CERTIFICATE/ { exit }' <<< "$certs" \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    end=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)
    if (( end > best_end )); then best=$hash; best_end=$end; fi
done
echo "$best"
