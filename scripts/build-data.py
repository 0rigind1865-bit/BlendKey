#!/usr/bin/env python3
"""將小麥注音（McBopomofo，MIT）原始詞庫轉為 BlendKey 詞庫 data.txt。

輸出行格式（沿用 mcbopomofo sorted 格式）：
    讀音(音節以-連接) 詞 ln機率
"""
import collections
import math
import pathlib
import sys

SRC = pathlib.Path(".lexicon-src")
OUT = pathlib.Path("Resources/data/data.txt")


def rows(name):
    path = SRC / name
    if not path.exists():
        # 缺原始檔就停：默默繼續會把 data.txt 覆寫成幾乎空的詞庫
        sys.exit(f"錯誤：找不到 {path}，請先跑 scripts/build-data.sh 下載原始詞庫")
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

# 注意：小麥的 exclusion.txt 是「語料計數修正表」（算 A 的次數時排除 B 裡的 A），
# 不是詞的排除清單；phrase.occ 已是計數後的結果，這裡不需要它。

# 破音字讀音權重（小麥 heterophony 表）：字的詞頻只該歸給常用讀音，
# 否則「和」的超高詞頻會灌進罕用音 ㄏㄨㄛˋ，把「或」壓下去。
hetero = {}  # 字 → {讀音 → 權重}
for name, factor in [("heterophony1.list", 1.0), ("heterophony2.list", 0.2), ("heterophony3.list", 0.05)]:
    for p in rows(name):
        if len(p) >= 2:
            hetero.setdefault(p[0], {})[p[1]] = factor


def reading_factor(ch, syl):
    if ch not in hetero:
        return 1.0  # 非破音字（或表上沒有）：不打折
    return hetero[ch].get(syl, 0.002)  # 表上有這個字但不是列出的讀音：重打折

entries = {}  # (讀音, 詞) -> 出現次數

# 詞條：BPMFMappings 每行「詞 音節…」
for p in rows("BPMFMappings.txt"):
    word, syls = p[0], p[1:]
    if not syls:
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
    weighted = counts.get(ch, 0) * reading_factor(ch, syl)
    entries[key] = max(entries.get(key, 0), weighted)

# 「一」「不」變調讀音（教育部《國語辭典簡編本》規則）：小麥詞庫多半只收一種讀音
# （「不是」只有 ㄅㄨˊ-ㄕˋ），打本調 ㄅㄨˋ-ㄕˋ 就組不出詞。兩種合規讀音都補上，分數同原詞。
# 規則：一／不在去聲前變 ㄧˊ／ㄅㄨˊ；一在陰平、陽平、上聲前變 ㄧˋ；數詞序詞（第一、一月、十一）、
# 詞尾、疊字動詞中間（看一看）的「一」只讀本調。
# ponytail: 專名與序詞（一女中、鈴木一朗）沒另列排除表，會多生出沒人打的讀音，無害只佔空間。
NUMERALS = set("零〇一二三四五六七八九十百千萬億兆兩廿卅佰仟")


def tone(syl):
    return {"ˊ": 2, "ˇ": 3, "ˋ": 4, "˙": 5}.get(syl[-1], 1)


def next_tone(word, syls, i):
    """下一字的本調：「不」算去聲、「一」算陰平、輕聲的「個」算去聲。"""
    nxt = word[i + 1]
    if nxt == "不":
        return 4
    if nxt == "一":
        return 1
    t = tone(syls[i + 1])
    return 4 if t == 5 and nxt == "個" else t


def yi_keeps_base(word, i):
    if i + 1 >= len(word):
        return True
    prev, nxt = (word[i - 1] if i else None), word[i + 1]
    return prev == "第" or prev in NUMERALS or nxt in NUMERALS or nxt == "月" or prev == nxt


def other_reading(word, syls, i):
    ch, s = word[i], syls[i]
    if ch == "一":
        if s in ("ㄧˊ", "ㄧˋ"):
            return "ㄧ"
        if s == "ㄧ" and not yi_keeps_base(word, i):
            t = next_tone(word, syls, i)
            return "ㄧˊ" if t == 4 else "ㄧˋ" if t in (1, 2, 3) else None
    elif ch == "不":
        if s == "ㄅㄨˊ":
            return "ㄅㄨˋ"
        if s == "ㄅㄨˋ" and i + 1 < len(word) and next_tone(word, syls, i) == 4:
            return "ㄅㄨˊ"
    return None


def sandhi_variants(word, syls):
    """三種變體：全部改本調；本調的「一」改變調；本調的「不」改變調。"""
    def apply(want):
        out = [other_reading(word, syls, i) or s if want(ch, s) else s for i, (ch, s) in enumerate(zip(word, syls))]
        return out if out != syls else None
    return [
        apply(lambda ch, s: (ch == "一" and s != "ㄧ") or (ch == "不" and s == "ㄅㄨˊ")),
        apply(lambda ch, s: ch == "一" and s == "ㄧ"),
        apply(lambda ch, s: ch == "不" and s == "ㄅㄨˋ"),
    ]


added = 0
for (reading, word), c in list(entries.items()):
    if len(word) < 2 or not ("一" in word or "不" in word):
        continue
    syls = reading.split("-")
    if len(syls) != len(word):
        continue
    for variant in sandhi_variants(word, syls):
        if variant and entries.setdefault(("-".join(variant), word), c) == c:
            added += 1
print(f"變調讀音：補 {added:,} 條")

total = sum(counts.values()) or 1


def score(key, c):
    s = math.log((c + 0.5) / total)
    # ponytail: unigram 加 0.5 平滑；零頻單字靠 BPMFBase 行序微調排序。
    # 品質不夠再升級 bigram。
    return s - 0.0001 * char_rank.get(key, 0)


scores = {key: score(key, c) for key, c in entries.items()}

# 常用詞優先（scripts/preferred-words.txt）：語料偏一般文章，工作用語常輸給同音詞
# （程式→城市、匯出→會出），或根本沒收（截圖、蝦皮）。表上的詞提到同讀音第一名，
# 只領先 0.01——使用者選一次別的字，學習加權（≥1.39）就翻回去。
NEW_WORD_SCORE = -12.0  # 詞庫沒有的詞：約當常見雙字詞，穩贏拆成單字
by_reading = collections.defaultdict(list)
for (r, w), s in scores.items():
    by_reading[r].append((s, w))
preferred = pathlib.Path(__file__).with_name("preferred-words.txt")
for line in preferred.read_text().splitlines():
    parts = line.split()
    if not parts or parts[0].startswith("#"):
        continue
    word, syls = parts[0], parts[1:]
    if syls:
        key = ("-".join(syls), word)
        scores.setdefault(key, NEW_WORD_SCORE)
        by_reading[key[0]].append((scores[key], word))
    keys = [k for k in scores if k[1] == word] if not syls else [key]
    if not keys:
        print(f"警告：{word} 不在詞庫，請在 preferred-words.txt 補上注音")
    for r, w in keys:
        rival = max((s for s, other in by_reading[r] if other != w), default=-math.inf)
        scores[(r, w)] = max(scores[(r, w)], rival + 0.01)

lines = [f"{r} {w} {s:.6f}" for (r, w), s in scores.items()]
lines.sort()
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("# format org.openvanilla.mcbopomofo.sorted\n" + "\n".join(lines) + "\n")
print(f"完成：{OUT}（{len(lines):,} 條）")
