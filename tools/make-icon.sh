#!/usr/bin/env bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Generate Resources/AppIcon.icns from tools/make-icon.swift.
# Same trick as the app itself: no Xcode, just swiftc + the SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="build/icon"
rm -rf "$WORK"
mkdir -p "$WORK/AppIcon.iconset"

echo "==> rendering 1024x1024 master"
swift tools/make-icon.swift "$WORK/icon-1024.png"

echo "==> scaling into an .iconset"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  size="${spec%% *}"
  name="${spec##* }"
  sips -z "$size" "$size" "$WORK/icon-1024.png" \
    --out "$WORK/AppIcon.iconset/icon_${name}.png" >/dev/null
done

echo "==> packing .icns"
mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns

ls -la Resources/AppIcon.icns
