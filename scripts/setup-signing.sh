#!/usr/bin/env bash
# One-time: create a self-signed code-signing certificate ("Workbench Local Signing") in the login keychain.
# bundle-app.sh signs with it, so the app keeps the same identity across rebuilds and the Screen Recording grant the verifier's
# screenshots need sticks instead of being dropped after every rebuild.
set -euo pipefail

NAME="Workbench Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "'$NAME' already exists in the login keychain."
  exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS="$(uuidgen)"

cat > "$DIR/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.conf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout "pass:$PASS" -out "$DIR/id.p12"
security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created '$NAME'. scripts/bundle-app.sh now signs with it."
echo "Rebuild (scripts/bundle-app.sh --install), then grant Screen Recording to Workbench once; it will stick from then on."
