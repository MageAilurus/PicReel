#!/usr/bin/env bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Build PicReel.app without Xcode (CommandLineTools only).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="PicReel"

# Prefer the stable self-signed identity if it exists: ad-hoc signatures pin
# TCC's designated requirement to the binary's cdhash, which changes on every
# rebuild -- so the Photos permission would need re-approving each time.
# A self-signed cert yields `identifier "com.photosift.app" and certificate
# leaf = H"..."`, which survives rebuilds.
#
# NOTE: the identity keeps its original "PhotoSift Local Signing" name on
# purpose. Regenerating the certificate would change its hash, and therefore the
# designated requirement, and therefore throw away the user's permission grant.
IDENTITY="${IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if [ -f "$HOME/.photosift-signing/identity.sha1" ]; then
    IDENTITY="$(cat "$HOME/.photosift-signing/identity.sha1")"
  else
    echo "!! no local signing identity found -- falling back to ad-hoc."
    echo "!! run ./make-signing-cert.sh once, or you will re-approve Photos access after every rebuild."
    IDENTITY="-"
  fi
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$APP_NAME"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "!! Resources/AppIcon.icns missing -- run ./tools/make-icon.sh"
fi

echo "==> codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" \
  --entitlements picreel.entitlements \
  --options runtime \
  --timestamp=none \
  "$APP" 2>&1

echo "==> verifying signature"
codesign --verify --strict --verbose=2 "$APP" 2>&1 || true
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true
echo "--- designated requirement (must stay cert-based, not cdhash):"
codesign -d -r- "$APP" 2>&1 | grep -i designated || true
echo "--- entitlements actually embedded:"
codesign -d --entitlements - "$APP" 2>/dev/null | tr -d '\0' | grep -E "photos|pictures" || echo "(none matched)"

echo "==> built: $(pwd)/$APP"
