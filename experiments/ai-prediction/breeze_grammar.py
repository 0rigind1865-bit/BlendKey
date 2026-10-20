#!/usr/bin/env python3
"""實驗 H：Breeze 校正改用「只能選同音字」的文法限制（llama.cpp GBNF）。
比較三種：(a) 看錯字句、自由改寫＋同音保險（實驗 G）、(b) 看錯字句＋文法限制、
(c) 不看錯字句，只用文法限制讓模型從同音字裡挑最通順的。
需要融鍵的 Breeze 伺服器在跑（偏好設定開啟智慧輸入，port 39281）。
    python3 experiments/ai-prediction/breeze_grammar.py
"""
import json, subprocess, time, urllib.request, statistics

SERVER = "http://127.0.0.1:39281/completion"
by_reading = {}
for line in open("Resources/data/data.txt", encoding="utf8"):
    p = line.split()
    if len(p) == 3 and len(p[1]) == 1 and "-" not in p[0]:
        by_reading.setdefault(p[0], []).append((float(p[2]), p[1]))
for r in by_reading:
    by_reading[r].sort(reverse=True)

rows = []
for line in open("Tests/Fixtures/sentences.tsv", encoding="utf8"):
    p = line.rstrip("\n").split("\t")
    if len(p) == 2:
        rows.append((p[0].split("-"), p[1]))
out = subprocess.run([".build/release/blendkey-cli", "--eval", "Tests/Fixtures/sentences.tsv"],
                     input="", capture_output=True, text=True).stdout
wrong = {}
for line in out.splitlines():
    if line.startswith("✗"):
        e, a = line[2:].split("　→　")
        wrong[e.strip()] = a.strip()

FEW = ("以下是注音輸入法打錯的同音字與改正後的句子。\n\n錯字：我們一起去吃反\n正確：我們一起去吃飯\n\n"
       "錯字：明天的會議改到下無\n正確：明天的會議改到下午\n\n錯字：這本書很有意思\n正確：這本書很有意思\n\n")


def gbnf(text, readings, top=12):
    parts = []
    for c, r in zip(text, readings):
        alts = [c] + [ch for _, ch in by_reading.get(r, [])[:top] if ch != c]
        parts.append("(" + " | ".join(json.dumps(a, ensure_ascii=False) for a in alts) + ")")
    return "root ::= " + " ".join(parts)


def ask(prompt, n, grammar=None, stop=None):
    body = {"prompt": prompt, "n_predict": n, "temperature": 0, "cache_prompt": True}
    if grammar: body["grammar"] = grammar
    if stop: body["stop"] = stop
    req = urllib.request.Request(SERVER, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t = time.perf_counter()
    content = json.load(urllib.request.urlopen(req, timeout=300))["content"]
    return content.strip(), (time.perf_counter() - t) * 1000


def merge(output, decoded, readings):
    if len(output) != len(decoded):
        return decoded
    return "".join(o if o != d and o in {ch for _, ch in by_reading.get(r, [])} else d
                   for o, d, r in zip(output, decoded, readings))


modes = {
    "(a) 看錯字句＋自由改寫": lambda d, r: ask(FEW + f"錯字：{d}\n正確：", len(d) * 2 + 8, stop=["\n"]),
    "(b) 看錯字句＋只能選同音": lambda d, r: ask(FEW + f"錯字：{d}\n正確：", len(d) * 3 + 4, gbnf(d, r)),
    "(c) 不看錯字句＋只能選同音": lambda d, r: ask("", len(d) * 3 + 4, gbnf(d, r)),
}
for name, run in modes.items():
    fixed = broken = still = kept = 0
    times, notes = [], []
    for readings, truth in rows:
        decoded = wrong.get(truth, truth)
        raw, ms = run(decoded, readings)
        times.append(ms)
        result = merge(raw, decoded, readings)
        if decoded != truth and result == truth: fixed += 1; notes.append(f"✅ {decoded} → {result}")
        elif decoded == truth and result != truth: broken += 1; notes.append(f"❌ 改壞 {decoded} → {result}")
        elif decoded != truth: still += 1; notes.append(f"・ {decoded} → {result}（應為 {truth}）")
        else: kept += 1
    print(f"=== {name} ===")
    print("\n".join(notes))
    print(f"錯的 {fixed + still} 句修好 {fixed}；對的 {kept + broken} 句改壞 {broken}；延遲中位數 {statistics.median(times):.0f} ms\n")
