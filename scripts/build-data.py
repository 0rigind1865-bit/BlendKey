#!/usr/bin/env python3
"""將小麥注音（McBopomofo，MIT）原始詞庫轉為 BlendKey 詞庫 data.txt。

輸出行格式（沿用 mcbopomofo sorted 格式）：
    讀音(音節以-連接) 詞 ln機率
"""
import collections
import math
import pathlib

SRC = pathlib.Path(".lexicon-src")
OUT = pathlib.Path("Resources/data/data.txt")


def rows(name):
    path = SRC / name
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts:
            yield parts


# 詞頻（語料出現次數）
counts = {}
for p in rows("phrase.occ"):
    if len(p) >= 2 and p[1].isdigit():
        counts[p[0]] = max(counts.get(p[0], 0), int(p[1]))

exclusions = {p[0] for p in rows("exclusion.txt")}

entries = {}  # (讀音, 詞) -> 出現次數

# 詞條：BPMFMappings 每行「詞 音節…」
for p in rows("BPMFMappings.txt"):
    word, syls = p[0], p[1:]
    if not syls or word in exclusions:
        continue
    if len(word) != len(syls):  # 防呆：字數與音節數不符的列
        continue
    key = ("-".join(syls), word)
    entries[key] = max(entries.get(key, 0), counts.get(word, 0))

# 單字（含破音字）：BPMFBase 行序反映同讀音內的預設排序
char_rank = {}
rank_within = collections.Counter()
for p in rows("BPMFBase.txt"):
    ch, syl = p[0], p[1]
    key = (syl, ch)
    if key not in char_rank:
        char_rank[key] = rank_within[syl]
        rank_within[syl] += 1
    entries[key] = max(entries.get(key, 0), counts.get(ch, 0))

total = sum(counts.values()) or 1


def score(key, c):
    s = math.log((c + 0.5) / total)
    # ponytail: unigram 加 0.5 平滑；零頻單字靠 BPMFBase 行序微調排序。
    # 品質不夠再升級 bigram。
    return s - 0.0001 * char_rank.get(key, 0)


lines = [f"{r} {w} {score((r, w), c):.6f}" for (r, w), c in entries.items()]
lines.sort()
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("# format org.openvanilla.mcbopomofo.sorted\n" + "\n".join(lines) + "\n")
print(f"完成：{OUT}（{len(lines):,} 條）")
