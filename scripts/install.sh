#!/bin/bash
# 安裝到 ~/Library/Input Methods 並重啟輸入法行程。
# 首次安裝需登出再登入；之後重跑本腳本即可熱更新（保持 Info.plist 不變）。
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/package-app.sh

DEST="$HOME/Library/Input Methods/BlendKey.app"
mkdir -p "$HOME/Library/Input Methods"
rsync -a --delete build/BlendKey.app/ "$DEST/"

# 舊行程結束後，下次聚焦輸入框時系統會自動重啟新版
pkill -x BlendKey || true

"$DEST/Contents/MacOS/BlendKey" install || true

cat <<'EOF'

安裝完成。
・首次安裝：請登出再登入，然後到「系統設定 › 鍵盤 › 輸入法 › ＋ › 繁體中文」加入「融鍵」。
・更新版本：已自動生效（切到任何輸入框即載入新行程）。
EOF
