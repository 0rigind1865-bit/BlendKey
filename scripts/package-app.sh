#!/bin/bash
# 打包 BlendKey.app：swift build → 組 .app bundle → 簽章
# 環境變數：CONFIG=debug|release（預設 release）、CODESIGN_IDENTITY
# 簽章：鑰匙圈裡有自製的「BlendKey」程式碼簽署憑證就用它（麥克風／語音權限重裝後不會再問），
# 沒有就 ad-hoc（每次重裝 macOS 都當成新 App，權限會重問）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"BlendKey"'; then
  CODESIGN_IDENTITY="BlendKey"
fi
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

# 詞庫：缺了就停，免得打出一個沒詞庫的 .app
[ -f Resources/data/data.txt ] || { echo "錯誤：缺 Resources/data/data.txt（先跑 scripts/build-data.sh）" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/data"
cp Resources/data/data.txt Resources/data/LICENSE-* "$APP/Contents/Resources/data/"

codesign --force --options runtime --entitlements Resources/BlendKey.entitlements --sign "$IDENTITY" "$APP"
echo "完成：$APP"
