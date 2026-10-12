#!/usr/bin/env bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Package PicReel as a distributable DMG.
#
# Unlike build.sh (which is for THIS machine and deliberately keeps the frozen
# self-signed identity so the Photos permission survives rebuilds), this targets
# somebody else's Mac. Two things change:
#
#   1. Universal binary. The dev build is arm64-only; Intel Macs can't run that.
#      SwiftPM can cross-build, so we hand it both arches.
#   2. A read-me explaining the one-time Gatekeeper bypass. Without an Apple
#      Developer ID there is no way around it — see the note at the bottom.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PicReel"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="build/dmg-stage"
APP="$STAGE/$APP_NAME.app"
OUT="${OUT:-$HOME/Downloads/${APP_NAME}-${VERSION}.dmg}"

IDENTITY="${IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f "$HOME/.photosift-signing/identity.sha1" ]; then
  IDENTITY="$(cat "$HOME/.photosift-signing/identity.sha1")"
fi
IDENTITY="${IDENTITY:--}"

echo "==> universal build (arm64 + x86_64)"
swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64

BIN=""
for candidate in ".build/out/Products/Release/$APP_NAME" ".build/apple/Products/Release/$APP_NAME"; do
  [ -f "$candidate" ] && BIN="$candidate" && break
done
if [ -z "$BIN" ]; then
  echo "!! universal binary not found (looked in .build/out and .build/apple)"
  exit 1
fi
echo "    $(lipo -archs "$BIN")"

echo "==> assembling $APP"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign"
codesign --force --sign "$IDENTITY" \
  --entitlements picreel.entitlements \
  --options runtime \
  --timestamp=none \
  "$APP"

# Drag-to-install target.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
PicReel —— 安装说明
====================

【怎么装】
把左边的 PicReel 拖到右边的「应用程序」文件夹里就行。


【第一次打开：要手动放行一次】

这个 App 没有 Apple 开发者签名和公证（那需要每年 99 美元的开发者账号），
所以 macOS 第一次会拦住它，提示「无法验证开发者」或者「Apple 无法检查
其是否包含恶意软件」。这不是 App 有问题，是签名机制对所有未公证软件
的默认行为。下面三种办法任选一种。

  办法一：右键 →「打开」
    打开「应用程序」文件夹 → 右键点 PicReel → 选「打开」→ 弹窗里再点「打开」。
    只需要做这一次，以后正常双击就行。
    （macOS 15 之后系统不再给这个「打开」按钮了，那就用办法二或三。）

  办法二：系统设置里「仍要打开」
    双击 PicReel → 弹窗点「完成」→ 打开「系统设置」→「隐私与安全性」
    → 往下翻到「安全性」那一栏 → 会出现「已阻止使用"PicReel"」→ 点「仍要打开」
    → 输密码确认。

  办法三：终端一行命令（最省事，一定有效）
    打开「终端」，粘贴下面这行回车：
        xattr -dr com.apple.quarantine /Applications/PicReel.app
    然后双击就能打开了。

注意：如果双击后你点了「移到废纸篓」或者「取消」，App 并没有被删干净，
重新拖一次再按上面的办法走一遍即可。


【第一次启动会要照片权限】
选「完全访问」。App 不联网、不上传，只读写你自己的照片库。
它读写的是系统「照片」App 的图库，别的文件一概不碰。


【默认是「演练模式 · 不写入」】
顶栏会显示「演练模式 · 不写入」。这时它只走流程、只做动画，
不会真的动你的照片 —— 可以放心先试手感。
确认没问题后，右上角齿轮进设置，关掉演练模式，才会真的写入图库。

删除是攒够一批再一起提交（⌘⏎），系统只弹一次确认框。


【键盘】
  →  或  ↓      跳过（这张不处理，放回牌堆底部）
  ↑             标记删除
  1–9 / 0       收进对应分类（第 10 个分类用 0）
  ←             把上一张拉回最前面
  ⌘Z            撤销
  ⌘⏎            提交删除
  Esc           从输入框切回快捷键操作

分类可以在顶栏的标签按钮里增删改名，0–10 个。


【系统要求】
macOS 13 或更高。Intel 和 Apple 芯片都能跑（通用二进制）。


【卸载】
直接删掉 App 就行。设置文件在
  ~/Library/Application Support/PhotoSift/
一起删掉即可（文件夹名是历史原因，没跟着改名）。
TXT

echo "==> building DMG"
rm -f "$OUT"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" >/dev/null

echo "==> verifying"
hdiutil verify "$OUT" >/dev/null && echo "    dmg verify OK"
codesign --verify --strict "$APP" && echo "    app signature OK"
echo "    arch: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "    size: $(du -h "$OUT" | cut -f1)"
echo "==> $OUT"
