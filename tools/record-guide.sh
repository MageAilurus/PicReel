#!/bin/bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Record the guide's entrance + page transition under --slowmo, then extract frames.
# Run from the photosift directory.
set -u
cd "$(dirname "$0")/.." 2>/dev/null || cd "$HOME/PicReel"

OUT=/tmp/guide-rec.mov
rm -f "$OUT" /tmp/gframes/*.png
mkdir -p /tmp/gframes

pkill -9 -f "PicReel.app/Contents/MacOS/PicReel" 2>/dev/null
# Wait for it to actually go: `open` on a still-running app just ACTIVATES it and
# silently drops --args, which looks exactly like "the flag does not work".
for i in $(seq 1 40); do
  pgrep -f "PicReel.app/Contents/MacOS/PicReel" >/dev/null || break
  sleep 0.25
done
sleep 1
rm -f ~/Library/Application\ Support/PhotoSift/run.log

# -n: always a fresh instance, never a re-activation of a stale one.
open -n build/PicReel.app --args --demo --guide --guideflow --slowmo

# Start recording as soon as the window exists.
WID=""
for i in $(seq 1 60); do
  WID=$(swift tools/windowid.swift PicReel 2>/dev/null)
  [ -n "$WID" ] && break
  sleep 0.2
done
if [ -z "$WID" ]; then echo "no window"; exit 1; fi
echo "window=$WID"

screencapture -v -l "$WID" -x "$OUT" &
REC=$!
sleep 12
kill -INT "$REC" 2>/dev/null
wait "$REC" 2>/dev/null
sleep 1

if [ ! -s "$OUT" ]; then echo "recording empty"; exit 1; fi
echo "recorded $(stat -f%z "$OUT") bytes"

swift tools/frames.swift "$OUT" /tmp/gframes 30 2>&1 | tail -2
echo "--- log ---"
grep -E "引导" ~/Library/Application\ Support/PhotoSift/run.log
