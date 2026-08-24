#!/bin/zsh
set -euo pipefail

IDENTITY="Dikte Native Local Signing"
ROOT_DIR="${0:A:h:h}"

if security find-identity -v -p codesigning | rg -F "\"$IDENTITY\"" >/dev/null; then
  print "Signing identity already exists: $IDENTITY"
  exit 0
fi

TEMP_DIR="$(mktemp -d /private/tmp/dikte-native-signing.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
  -config "$ROOT_DIR/Signing/openssl.cnf" \
  -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem"
openssl pkcs12 -export -legacy -passout pass:dikte-native-local \
  -inkey "$TEMP_DIR/key.pem" -in "$TEMP_DIR/cert.pem" -out "$TEMP_DIR/identity.p12"
security import "$TEMP_DIR/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P dikte-native-local -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -d -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$TEMP_DIR/cert.pem"

security find-identity -v -p codesigning | rg -F "\"$IDENTITY\"" >/dev/null || {
  print -u2 "Signing identity could not be installed: $IDENTITY"
  exit 1
}
print "Installed signing identity: $IDENTITY"
