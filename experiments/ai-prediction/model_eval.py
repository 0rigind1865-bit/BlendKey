#!/usr/bin/env python3
"""實驗 I：換模型用同一套考題比較（補句＋校正），方便比 Breeze 與更小的模型。
- 補句：81 句切在詞邊界，只給前半段，看開頭猜對幾個字（同實驗 E／G）
- 校正：90 句解碼後，看錯字句＋文法限制只能選同音字（同實驗 H 的 (b)）

先開伺服器（任何 .gguf 都可以），再跑（在專案根目錄）：
    llama-server -m 模型.gguf --host 127.0.0.1 --port 39290 -ngl 99 -c 1024
    swift build -c release --product blendkey-cli
    python3 experiments/ai-prediction/model_eval.py 39290
"""
import json, statistics, subprocess, sys, time, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "39290"
SERVER = f"http://127.0.0.1:{PORT}/completion"
PUNCT = "，。！？、：；「」…\"'.,!? \n"

words, by_reading = set(), {}
for line in open("Resources/data/data.txt", encoding="utf8"):
    p = line.split()
    if len(p) != 3:
        continue
    words.add(p[1])
    if len(p[1]) == 1 and "-" not in p[0]:
        by_reading.setdefault(p[0], []).append((float(p[2]), p[1]))
for r in by_reading:
    by_reading[r].sort(reverse=True)

rows = []
for line in open("Tests/Fixtures/sentences.tsv", encoding="utf8"):
    p = line.rstrip("\n").split("\t")
    if len(p) == 2:
        rows.append((p[0].split("-"), p[1]))


def ask(prompt, n, grammar=None, stop=None):
    body = {"prompt": prompt, "n_predict": n, "temperature": 0, "cache_prompt": True}
    if grammar: body["grammar"] = grammar
    if stop: body["stop"] = stop
    req = urllib.request.Request(SERVER, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t = time.perf_counter()
    content = json.load(urllib.request.urlopen(req, timeout=300))["content"]
    return content, (time.perf_counter() - t) * 1000


def cut(sentence):
    i, bounds = 0, []
    while i < len(sentence):
        for n in range(min(6, len(sentence) - i), 0, -1):
            if n == 1 or sentence[i:i + n] in words:
                i += n; bounds.append(i); break
    c = [b for b in bounds if 2 <= b <= len(sentence) - 2]
    return min(c, key=lambda b: abs(b - len(sentence) / 2)) if c else None


ask("暖機", 1)

# ---------- 補句 ----------
total = hit2 = 0
times, samples = [], []
cases = [(s[:c], s[c:]) for _, s in rows if len(s) >= 6 and (c := cut(s))]
for given, truth in cases:
    truth = "".join(ch for ch in truth if ch not in PUNCT)
    raw, ms = ask(given, 16, stop=["\n", "。", "！", "？"])
    times.append(ms)
    guess = "".join(ch for ch in raw if ch not in PUNCT)
    n = 0
    for a, b in zip(guess, truth):
        if a != b: break
        n += 1
    total += n; hit2 += n >= 2
    if len(samples) < 12: samples.append(f"{given}【{truth}】→ {raw.strip()}（對 {n} 字）")
print(f"=== 補句（{len(cases)} 句）===")
print("\n".join(samples))
print(f"開頭至少對 2 字：{hit2}/{len(cases)}（{hit2 * 100 // len(cases)}%）　平均對 {total / len(cases):.2f} 字　延遲中位數 {statistics.median(times):.0f} ms\n")

# ---------- 校正 ----------
out = subprocess.run([".build/release/blendkey-cli", "--eval", "Tests/Fixtures/sentences.tsv"],
                     input="", capture_output=True, text=True).stdout
wrong = {}
for line in out.splitlines():
    if line.startswith("✗"):
        e, a = line[2:].split("　→　")
        wrong[e.strip()] = a.strip()
FEW = ("以下是注音輸入法打錯的同音字與改正後的句子。\n\n錯字：我們一起去吃反\n正確：我們一起去吃飯\n\n"
       "錯字：明天的會議改到下無\n正確：明天的會議改到下午\n\n錯字：這本書很有意思\n正確：這本書很有意思\n\n")


def gbnf(text, readings):
    parts = []
    for c, r in zip(text, readings):
        alts = [c] + [ch for _, ch in by_reading.get(r, [])[:12] if ch != c]
        parts.append("(" + " | ".join(json.dumps(a, ensure_ascii=False) for a in alts) + ")")
    return "root ::= " + " ".join(parts)


fixed = broken = still = 0
times, notes = [], []
for readings, truth in rows:
    decoded = wrong.get(truth, truth)
    raw, ms = ask(FEW + f"錯字：{decoded}\n正確：", len(decoded) * 3 + 4, gbnf(decoded, readings))
    times.append(ms)
    result = raw.strip() if len(raw.strip()) == len(decoded) else decoded
    if decoded != truth and result == truth: fixed += 1; notes.append(f"✅ {decoded} → {result}")
    elif decoded == truth and result != truth: broken += 1; notes.append(f"❌ 改壞 {decoded} → {result}")
    elif decoded != truth: still += 1; notes.append(f"・ {decoded} → {result}（應為 {truth}）")
print(f"=== 校正（{len(rows)} 句）===")
print("\n".join(notes))
print(f"錯的 {fixed + still} 句修好 {fixed}；對的 {len(rows) - fixed - still} 句改壞 {broken}；延遲中位數 {statistics.median(times):.0f} ms")
