#!/usr/bin/env bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Create a stable local code-signing identity for PhotoSift.
#
# Why: ad-hoc signing (codesign -s -) pins TCC's "designated requirement" to the
# binary's cdhash, which changes on every rebuild. macOS then treats each build as
# a brand-new app, so the Photos permission has to be re-approved (or silently
# fails) after every single build. A self-signed cert with a stable CN gives a
# stable designated requirement instead.
#
# Removal:  security delete-identity -c "PhotoSift Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail

CN="PhotoSift Local Signing"
DIR="$HOME/.photosift-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12PASS="photosift-local"

if [ -f "$DIR/identity.sha1" ] && security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "identity already set up:"
  echo "  CN    : $CN"
  echo "  SHA-1 : $(cat "$DIR/identity.sha1")"
  echo "  file  : $DIR"
  exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = codesign_ext

[ dn ]
CN = PhotoSift Local Signing

[ codesign_ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
1.2.840.113635.100.6.1.14 = critical,DER:0500
EOF

echo "==> generating self-signed cert"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout key.pem -out cert.pem -config openssl.cnf

echo "==> verifying Apple code-signing OID is present"
openssl x509 -in cert.pem -noout -text | grep -A1 "1.2.840.113635.100.6.1.14" || {
  echo "!! Apple code-signing OID missing — codesign may not accept this identity"; }

echo "==> bundling into PKCS#12"
openssl pkcs12 -export -out identity.p12 \
  -inkey key.pem -in cert.pem -name "$CN" -passout "pass:$P12PASS"

echo "==> importing into login keychain (no UI prompt: -A grants codesign access)"
security import identity.p12 -k "$KEYCHAIN" -P "$P12PASS" -A \
  -T /usr/bin/codesign -T /usr/bin/security

# `security find-identity -p codesigning` will NOT list this cert: the policy
# requires a trusted identity, and a self-signed cert isn't trusted. codesign
# itself doesn't care -- it signs happily with the cert's SHA-1. So we address
# the identity by hash. (These checks in codesign run against the certificate,
# so codesign --verify may warn; the signature is still valid and, crucially,
# the designated requirement is stable across rebuilds.)
SHA1=$(openssl x509 -in cert.pem -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')
echo "$SHA1" > "$DIR/identity.sha1"

echo "==> result"
echo "  CN    : $CN"
echo "  SHA-1 : $SHA1"
echo "  file  : $DIR/identity.sha1"

echo
echo "done. build.sh picks this identity up automatically."
echo "designated requirement will be:"
echo "  identifier \"com.photosift.app\" and certificate leaf = H\"$SHA1\""
echo "remove with:  security delete-certificate -c \"$CN\" \"$KEYCHAIN\""
