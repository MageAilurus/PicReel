#!/bin/bash
# Copyright (C) 2026 MageAilurus
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PicReel —— 键盘驱动的 Mac 照片整理工具

# Record the PicReel window while pressing ONE key, then stop cleanly.
# Usage: capture-key.sh <keycode> [out.mov]
set -u
KEY="${1:-124}"
OUT="${2:-/tmp/rec.mov}"

B=$(osascript -e 'tell application "System Events" to tell process "PicReel" to get {position, size} of window 1' 2>&1)
X=$(echo "$B" | cut -d, -f1 | tr -d ' ')
Y=$(echo "$B" | cut -d, -f2 | tr -d ' ')
W=$(echo "$B" | cut -d, -f3 | tr -d ' ')
H=$(echo "$B" | cut -d, -f4 | tr -d ' ')
if [ -z "$X" ] || [ -z "$W" ]; then echo "cannot read PicReel window bounds"; exit 1; fi

rm -f "$OUT"
screencapture -v -R "$X,$Y,$W,$H" "$OUT" &
REC=$!
sleep 1.5

osascript -e "tell application \"System Events\" to key code $KEY" >/dev/null 2>&1

sleep 2.0
kill -INT "$REC" 2>/dev/null
wait "$REC" 2>/dev/null
sleep 1.0

if [ -s "$OUT" ]; then
  echo "recorded $(stat -f%z "$OUT") bytes -> $OUT"
else
  echo "recording is empty"
  exit 1
fi
