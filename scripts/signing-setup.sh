#!/bin/sh
# One-time: create a self-signed code-signing certificate in its own keychain, so rebuilt
# Pounce builds keep the same identity and macOS keeps the Accessibility permission.
set -e
kc="$HOME/Library/Keychains/pounce-signing.keychain-db"
# --export: print the identity as base64 .p12 for the MACOS_CERTIFICATE_P12 release secret.
#   gh secret set MACOS_CERTIFICATE_P12 < <(scripts/signing-setup.sh --export)
#   gh secret set MACOS_CERTIFICATE_PASSWORD --body pounce
if [ "${1:-}" = "--export" ]; then
  security unlock-keychain -p pounce "$kc"
  out=$(mktemp -d)/pounce.p12
  security export -k "$kc" -t identities -f pkcs12 -P pounce -o "$out" >/dev/null
  base64 -i "$out"
  rm -f "$out"
  exit 0
fi
security find-identity -p codesigning | grep -q "Pounce Local Signing" && { echo "already set up"; exit 0; }
tmp=$(mktemp -d)
cat > "$tmp/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Pounce Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 3650 -config "$tmp/c.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -out "$tmp/p.p12" -passout pass:pounce -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -out "$tmp/p.p12" -passout pass:pounce
[ -f "$kc" ] || security create-keychain -p pounce "$kc"
security set-keychain-settings "$kc"
security unlock-keychain -p pounce "$kc"
security import "$tmp/p.p12" -k "$kc" -P pounce -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pounce "$kc" >/dev/null
# shellcheck disable=SC2046  # one keychain path per word
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$kc"
rm -rf "$tmp"
echo "Created 'Pounce Local Signing' in $kc"
