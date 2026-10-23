#!/usr/bin/env python3
"""實驗 J：語音整理順便改同音錯字，量「改對／改壞」。
比兩種提示：A＝現行（只去贅字、補標點、不改用字），B＝加上「聽錯的同音字改正」範例。
評分：去掉標點後跟正確答案比編輯距離——變近算改對、變遠算改壞，完全一樣算全對。
錯字句部分取自實際語音測試；正確句用來看會不會把對的改壞。

先開伺服器，再跑（在專案根目錄）：
    llama-server -m ~/Library/Application\\ Support/BlendKey/models/Llama-3.2-Taiwan-3B.Q3_K_M.gguf \\
        --host 127.0.0.1 --port 39290 -ngl 99 -c 1024
    python3 experiments/ai-prediction/voice_polish_eval.py 39290
"""
import difflib, json, sys, time, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "39290"
PUNCT = set("，。！？、：；「」…,.!?:; \n")

# (語音逐字稿, 正確答案)
CASES = [
    # 有錯字
    ("林中案退課現在只剩最後一個字繼續聽", "語音中按退格現在只剩最後一個字繼續聽"),
    ("中等問題與架構以起修正", "中等問題與架構一起修正"),
    ("AI還在整理室又按右Option會先把上一句送上去", "AI還在整理時又按右Option會先把上一句送上去"),
    ("明天的會議改到下無三點", "明天的會議改到下午三點"),
    ("這個案子的燈光要再加兩隻側光", "這個案子的燈光要再加兩支側光"),
    ("我們一起去吃反吧", "我們一起去吃飯吧"),
    ("報價單我等一下會寄過去給你確任", "報價單我等一下會寄過去給你確認"),
    ("請幫我確認一下音箱的配線有沒有接號", "請幫我確認一下音箱的配線有沒有接好"),
    ("下個禮拜的演唱會要提早進場裝台", "下個禮拜的演唱會要提早進場裝台"),
    ("這次的舞台設計很有創億", "這次的舞台設計很有創意"),
    ("麻煩你把檔案傳到群組離", "麻煩你把檔案傳到群組裡"),
    ("今天天氣很好我們去公園三步", "今天天氣很好我們去公園散步"),
    ("我已經把程式碼推上去了你再拉下來看看", "我已經把程式碼推上去了你再拉下來看看"),
    ("這台印表機的噴頭好像賭住了", "這台印表機的噴頭好像堵住了"),
    ("薪水這個月會晚兩天發放請大家見諒", "薪水這個月會晚兩天發放請大家見諒"),
    ("他說他明天不能來因為要去看一聲", "他說他明天不能來因為要去看醫生"),
    ("這個功能我覺得還要在測是一下", "這個功能我覺得還要再測試一下"),
    ("燈光師傅已經到現場了正在掉燈", "燈光師傅已經到現場了正在調燈"),
    ("你可以幫我訂一張明天早上的高鐵票嗎", "你可以幫我訂一張明天早上的高鐵票嗎"),
    ("這個月的電費比上個月多了快一倍", "這個月的電費比上個月多了快一倍"),
    # 正確、只有贅字（應該只去贅字，不改用字）
    ("嗯那個我明天大概十點到然後再討論", "我明天大概十點到再討論"),
    ("就是說這個價格我們可以再談談", "這個價格我們可以再談談"),
    ("好的沒問題我等一下處理", "好的沒問題我等一下處理"),
    ("三樓的會議室已經訂好了", "三樓的會議室已經訂好了"),
    ("然後那個喇叭的位置要往左邊移一點", "喇叭的位置要往左邊移一點"),
]

HEAD_A = "以下是口語逐字稿和整理後的文字。整理時去掉「嗯、那個、就是、然後」等贅字與重複的話，補上標點，意思和用字不變。\n\n"
SHOTS_A = [
    ("嗯那個我明天早上大概十點左右到然後我們再討論一下", "我明天早上大概十點左右到，我們再討論一下。"),
    ("這個這個案子的燈光就是要再加兩支側光喔", "這個案子的燈光要再加兩支側光。"),
    ("好的，謝謝你。", "好的，謝謝你。"),
]
HEAD_B = "以下是語音辨識的逐字稿和整理後的文字。整理時去掉「嗯、那個、就是、然後」等贅字與重複的話，補上標點，並把聽錯的同音字改成正確的字；其他用字和意思不變。\n\n"
SHOTS_B = [
    ("嗯那個我明天早上大概十點左右到然後我們再討論一下", "我明天早上大概十點左右到，我們再討論一下。"),
    ("這個這個案子的燈光就是要再加兩支側光喔", "這個案子的燈光要再加兩支側光。"),
    ("我等一下把檔案寄給你確任", "我等一下把檔案寄給你確認。"),
    ("我們這週末去看電影好不好", "我們這週末去看電影好不好？"),
    ("會議室的投影機好像懷了", "會議室的投影機好像壞了。"),
    ("好的，謝謝你。", "好的，謝謝你。"),
]


def prompt(head, shots, text):
    return head + "".join(f"口語：{a}\n整理：{b}\n\n" for a, b in shots) + f"口語：{text}\n整理："


def ask(p, n):
    body = {"prompt": p, "n_predict": n, "temperature": 0, "cache_prompt": True, "stop": ["\n"]}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/completion", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t = time.perf_counter()
    out = json.load(urllib.request.urlopen(req, timeout=300))["content"].strip()
    return out, (time.perf_counter() - t) * 1000


def norm(s):
    return "".join(c for c in s if c not in PUNCT)


def dist(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


# 單字讀音（去聲調）：判斷「同音」用
SOUNDS = {}
for line in open("Resources/data/data.txt", encoding="utf8"):
    p = line.split()
    if len(p) == 3 and len(p[1]) == 1 and "-" not in p[0]:
        SOUNDS.setdefault(p[1], set()).add(p[0].strip("ˊˇˋ˙"))
FILLERS = {"嗯", "呃", "啊", "喔", "那個", "就是", "就是說", "然後", "然後那個", "就是說那個"}


def safe(text, out):
    """只准：換成同音字（不管聲調）、刪贅字或重複的話、加標點。其他改動＝模型自己編的。"""
    a, b = norm(text), norm(out)
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op == "equal":
            continue
        if op == "replace" and i2 - i1 == j2 - j1:
            if all(SOUNDS.get(x, set()) & SOUNDS.get(y, set()) for x, y in zip(a[i1:i2], b[j1:j2])):
                continue
            return False
        if op == "delete":
            gone = a[i1:i2]
            if gone in FILLERS or a[i2:i2 + len(gone)] == gone or a[i1 - len(gone):i1] == gone:
                continue
        return False
    return True


def guard(text, out):
    # 跟 SmartInput.polish 一樣：長度差太多當亂寫，退回原文
    ok = out and len(out) * 2 >= len(text) and len(out) <= len(text) * 3 // 2 + 2
    return out if ok else text


ask("暖機", 1)
for name, head, shots, checked in [("A 現行", HEAD_A, SHOTS_A, False), ("A＋檢查", HEAD_A, SHOTS_A, True),
                                   ("B 改錯字", HEAD_B, SHOTS_B, False), ("B＋檢查", HEAD_B, SHOTS_B, True)]:
    better = worse = exact = 0
    times = []
    print(f"\n===== {name} =====")
    for text, want in CASES:
        out, ms = ask(prompt(head, shots, text), len(text) * 2 + 8)
        out = guard(text, out)
        if checked and not safe(text, out):
            out = text
        times.append(ms)
        before, after = dist(norm(text), norm(want)), dist(norm(out), norm(want))
        exact += norm(out) == norm(want)
        mark = "改對" if after < before else "改壞" if after > before else "　　"
        better += after < before
        worse += after > before
        if mark.strip() or norm(out) != norm(want):
            print(f"{mark} {text} → {out}")
    times.sort()
    print(f"改對 {better}、改壞 {worse}、全對 {exact}/{len(CASES)}、中位延遲 {times[len(times) // 2]:.0f} ms")
