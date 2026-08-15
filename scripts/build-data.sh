#!/bin/bash
# 抓取小麥注音（McBopomofo，MIT 授權）詞庫原始檔，轉成 Resources/data/data.txt
set -euo pipefail
cd "$(dirname "$0")/.."

RAW="https://raw.githubusercontent.com/openvanilla/McBopomofo/master"
mkdir -p .lexicon-src Resources/data

for f in BPMFBase.txt BPMFMappings.txt phrase.occ; do
  [ -f ".lexicon-src/$f" ] || curl -fsSL "$RAW/Source/Data/$f" -o ".lexicon-src/$f"
done
# 非必要檔：抓不到不擋流程
[ -f ".lexicon-src/exclusion.txt" ] || curl -fsSL "$RAW/Source/Data/exclusion.txt" -o ".lexicon-src/exclusion.txt" || true
[ -f "Resources/data/LICENSE-McBopomofo.txt" ] || curl -fsSL "$RAW/LICENSE.txt" -o "Resources/data/LICENSE-McBopomofo.txt" || true

python3 scripts/build-data.py
