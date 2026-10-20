#!/usr/bin/env python3
"""實驗 G：開源「續寫型」模型（聯發科 Breeze-7B-Base）做 AI 補句與 AI 校正，
和 Apple 內建模型（實驗 E、F）用同一套考題比較。

先在另一個終端機開 llama.cpp 伺服器（模型只在本機跑）：
    llama-server -m Breeze-7B-Base-v1_0.Q3_K_M.gguf --port 8089 -ngl 99 -c 1024
再跑（在專案根目錄）：
    swift build -c release --product blendkey-cli
    python3 experiments/ai-prediction/breeze_eval.py
"""
import json
import os
import statistics
import subprocess
import time
import urllib.request

SERVER = "http://127.0.0.1:8089/completion"
DATA = "Resources/data/data.txt"
FIXTURE = "Tests/Fixtures/sentences.tsv"
PUNCT = "，。！？、：；「」…\"'.,!? \n"


def complete(prompt, n_predict, stop):
    body = json.dumps({
        "prompt": prompt, "n_predict": n_predict, "temperature": 0,
        "stop": stop, "cache_prompt": True,
    }).encode()
    request = urllib.request.Request(SERVER, body, {"Content-Type": "application/json"})
    start = time.perf_counter()
    with urllib.request.urlopen(request, timeout=300) as response:  # 8 GB 記憶體會借用交換空間，偶爾很慢
        result = json.load(response)
    return result["content"], (time.perf_counter() - start) * 1000


# 詞庫：所有詞（斷詞用）與「讀音 → 單字」（同音保險用）
words, chars_by_reading = set(), {}
for line in open(DATA, encoding="utf8"):
    parts = line.split()
    if len(parts) != 3:
        continue
    reading, word, _ = parts
    words.add(word)
    if len(word) == 1 and "-" not in reading:
        chars_by_reading.setdefault(reading, set()).add(word)

rows = []
for line in open(FIXTURE, encoding="utf8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 2:
        rows.append((parts[0].split("-"), parts[1]))


def word_boundary_cut(sentence):
    """最長詞優先斷詞，找最接近一半的詞邊界（同實驗 E 的公平性複查）"""
    i, bounds = 0, []
    while i < len(sentence):
        for length in range(min(6, len(sentence) - i), 0, -1):
            if length == 1 or sentence[i:i + length] in words:
                i += length
                bounds.append(i)
                break
    candidates = [b for b in bounds if 2 <= b <= len(sentence) - 2]
    return min(candidates, key=lambda b: abs(b - len(sentence) / 2)) if candidates else None


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


# ---------- AI 補句 ----------（ONLY=correction 可跳過）
complete("暖機", 1, [])
if os.environ.get("ONLY") == "correction":
    rows_for_completion = []
else:
    rows_for_completion = rows
cases = []
for _, sentence in rows_for_completion:
    if len(sentence) >= 6 and (cut := word_boundary_cut(sentence)):
        cases.append((sentence[:cut], sentence[cut:]))

prefix_total, at_least2, exact, times, samples = 0, 0, 0, [], []
for given, truth in cases:
    truth = "".join(c for c in truth if c not in PUNCT)
    raw, ms = complete(given, 12, ["\n", "。", "！", "？", "，"])
    times.append(ms)
    guess = "".join(c for c in raw if c not in PUNCT)
    correct = common_prefix(guess, truth)
    prefix_total += correct
    at_least2 += correct >= 2
    exact += guess.startswith(truth)
    if len(samples) < 15:
        samples.append(f"{given}【{truth}】→ {guess}（對 {correct} 字）")

n = max(1, len(cases))
if cases:
  print(f"=== AI 補句（{n} 句，切在詞邊界）===")
  print("\n".join(samples))
  print(f"開頭平均猜對 {prefix_total / n:.2f} 字")
  print(f"開頭至少對 2 字：{at_least2}/{n}（{at_least2 * 100 // n}%）")
  print(f"後半段整段猜中：{exact}/{n}（{exact * 100 // n}%）")
  print(f"延遲中位數 {statistics.median(times):.0f} ms\n")

# ---------- AI 校正 ----------
# 解碼結果：blendkey-cli --eval 只印錯的（✗ 預期　→　實際），其他就是解對了
eval_out = subprocess.run(
    [".build/release/blendkey-cli", "--eval", FIXTURE],
    input="", capture_output=True, text=True,
).stdout
wrong = {}
for line in eval_out.splitlines():
    if line.startswith("✗"):
        expected, actual = line[2:].split("　→　")
        wrong[expected.strip()] = actual.strip()

FEW_SHOT = (
    "以下是注音輸入法打錯的同音字與改正後的句子。\n\n"
    "錯字：我們一起去吃反\n正確：我們一起去吃飯\n\n"
    "錯字：明天的會議改到下無\n正確：明天的會議改到下午\n\n"
    "錯字：這本書很有意思\n正確：這本書很有意思\n\n"
)


def homophone_merge(output, decoded, readings):
    """逐字合併：字數一樣時只採用同音的改動（同實驗 F 的 --merge）"""
    if len(output) != len(decoded) or len(output) != len(readings):
        return None
    return "".join(
        o if o != d and o in chars_by_reading.get(r, ()) else d
        for o, d, r in zip(output, decoded, readings)
    )


fixed = broken = still_wrong = kept = rejected = 0
times, notes = [], []
for readings, truth in rows:
    decoded = wrong.get(truth, truth)
    raw, ms = complete(FEW_SHOT + f"錯字：{decoded}\n正確：", 40, ["\n"])
    times.append(ms)
    cleaned = "".join(c for c in raw.strip() if c not in PUNCT)
    merged = homophone_merge(cleaned, decoded, readings)
    if merged is None:
        rejected += 1
        merged = decoded
    was_right, is_right = decoded == truth, merged == truth
    if not was_right and is_right:
        fixed += 1
        notes.append(f"✅ 修好：{decoded} → {merged}")
    elif was_right and not is_right:
        broken += 1
        notes.append(f"❌ 改壞：{decoded} → {merged}")
    elif not was_right:
        still_wrong += 1
        notes.append(f"・沒修好：{decoded} → {merged}（應為 {truth}；AI 寫「{cleaned}」）")
    else:
        kept += 1

print(f"=== AI 校正（{len(rows)} 句）===")
print("\n".join(notes))
print(f"原本錯的 {fixed + still_wrong} 句：修好 {fixed}、沒修好 {still_wrong}")
print(f"原本對的 {kept + broken} 句：維持 {kept}、改壞 {broken}")
print(f"輸出字數不對被擋：{rejected}")
print(f"整句正確：{kept + fixed}/{len(rows)}（原本 {kept + broken}/{len(rows)}）")
print(f"延遲中位數 {statistics.median(times):.0f} ms")
