#!/bin/bash
# 打包 BlendKey.app：swift build → 組 .app bundle → 簽章
# 環境變數：CONFIG=debug|release（預設 release）、CODESIGN_IDENTITY（預設 ad-hoc "-"）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product BlendKey
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BlendKey"

APP="build/BlendKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/BlendKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
cp Resources/BlendKey.tiff "$APP/Contents/Resources/" 2>/dev/null || echo "（尚無圖示，略過）"
cp -R Resources/zh-Hant.lproj "$APP/Contents/Resources/"

# 詞庫（M1 起由 scripts/build-data.sh 產生）
if [ -f Resources/data/data.txt ]; then
  mkdir -p "$APP/Contents/Resources/data"
  cp Resources/data/data.txt Resources/data/LICENSE-* "$APP/Contents/Resources/data/" 2>/dev/null || true
fi

codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "完成：$APP"
