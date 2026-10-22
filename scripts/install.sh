#!/bin/bash
# 安裝到 ~/Library/Input Methods 並重啟輸入法行程。
# 首次安裝需登出再登入；之後重跑本腳本即可熱更新（保持 Info.plist 不變）。
#
# --system：改裝到 /Library/Input Methods（需管理員密碼）。好處：密碼管理器或終端機開著
# 「安全輸入」時，系統不會把它反灰（裝在家目錄的會）。代價：每次更新都要密碼；換位置後要登出一次。
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/package-app.sh

if [ "${1:-}" = "--system" ]; then
  DEST="/Library/Input Methods/BlendKey.app"
  sudo mkdir -p "/Library/Input Methods"
  sudo rsync -a --delete build/BlendKey.app/ "$DEST/"
  sudo chown -R root:wheel "$DEST"
  sudo chmod -R a+rX "$DEST"
  # 同一個 bundle id 不能兩份並存，移掉家目錄那份
  [ -d "$HOME/Library/Input Methods/BlendKey.app" ] && rm -rf "$HOME/Library/Input Methods/BlendKey.app" && echo "已移除家目錄的舊版，請登出再登入一次"
else
  DEST="$HOME/Library/Input Methods/BlendKey.app"
  if [ -d "/Library/Input Methods/BlendKey.app" ]; then
    echo "系統層已裝有 BlendKey（/Library/Input Methods）。要改回家目錄請先：sudo rm -rf '/Library/Input Methods/BlendKey.app'，或改用 scripts/install.sh --system 更新" >&2
    exit 1
  fi
  mkdir -p "$HOME/Library/Input Methods"
  rsync -a --delete build/BlendKey.app/ "$DEST/"
fi

# 舊行程結束後，下次聚焦輸入框時系統會自動重啟新版
pkill -x BlendKey || true

"$DEST/Contents/MacOS/BlendKey" install || true

cat <<'EOF'

安裝完成。
・首次安裝：請登出再登入，然後到「系統設定 › 鍵盤 › 輸入法 › ＋ › 繁體中文」加入「融鍵」。
・更新版本：已自動生效（切到任何輸入框即載入新行程）。
EOF
