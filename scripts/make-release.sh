#!/bin/bash
# 打包可散布的 zip：BlendKey.app ＋ 雙擊安裝腳本 ＋ 說明
# 用法：scripts/make-release.sh [版本號]
# 簽章：預設用鑰匙圈裡第一個可用身分；有 Developer ID 時設 CODESIGN_IDENTITY 以便公證
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1{print $2}')}"
[ -n "$IDENTITY" ] || IDENTITY="-"

echo "版本 $VERSION／簽章身分：$IDENTITY"
CODESIGN_IDENTITY="$IDENTITY" scripts/package-app.sh

STAGE="build/融鍵 BlendKey $VERSION"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/BlendKey.app "$STAGE/"
cp scripts/installer-template.command "$STAGE/安裝融鍵.command"
chmod +x "$STAGE/安裝融鍵.command"

cat > "$STAGE/請先讀我.txt" <<'EOF'
融鍵 BlendKey — 中英混輸零阻礙的 macOS 注音輸入法

【安裝】
1. 在「安裝融鍵.command」上按右鍵 →「打開」→ 再按一次「打開」
   （因為這是免費開源軟體、沒有付費的 Apple 開發者憑證，
     所以第一次要用右鍵打開來略過系統警告，這是正常的）
2. 依畫面指示登出再登入
3. 系統設定 › 鍵盤 › 輸入來源 › 編輯 › ＋ › 繁體中文 › 融鍵

【怎麼用】
切換到融鍵後，點選單列的融鍵圖示 › 操作說明…

【移除】
把 ~/Library/Input Methods/BlendKey.app 丟到垃圾桶，
並在系統設定的輸入來源中移除「融鍵」即可。
學習資料在 ~/Library/Application Support/BlendKey/

【原始碼與問題回報】
https://github.com/0rigind1865-bit/BlendKey
EOF

ZIP="build/BlendKey-$VERSION.zip"
rm -f "$ZIP"
(cd build && zip -qry "$(basename "$ZIP")" "$(basename "$STAGE")")

echo "完成：$ZIP（$(du -h "$ZIP" | cut -f1)）"
codesign -dv "$STAGE/BlendKey.app" 2>&1 | grep -E 'Authority|Signature' | head -2 || true
if [[ "$IDENTITY" == *"Developer ID"* ]]; then
  echo "偵測到 Developer ID —— 可接著公證："
  echo "  xcrun notarytool submit \"$ZIP\" --keychain-profile <設定檔> --wait"
else
  echo "注意：非 Developer ID 簽章，他人下載後需依「請先讀我.txt」用右鍵開啟安裝程式。"
fi
