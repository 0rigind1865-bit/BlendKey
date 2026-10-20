// 實驗 D：「小抄法」——把使用者自己的詞語接續（userphrases.json 的 transitions）
// 附在問題裡，看 AI 能不能用他的習慣猜下一個詞。
// 考法：抽 30 組「前詞→後詞」，考哪一題就把那一題從小抄和查表裡拿掉（不能抄答案）。
// 資料只在本機讀取，不會寫進任何檔案。
// 編譯：swiftc -O cheatsheet.swift -o /tmp/cheatsheet && /tmp/cheatsheet
import Foundation
import FoundationModels

struct Pair: Hashable { let previous: String; let next: String; let count: Int }

let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("BlendKey/userphrases.json")
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let transitions = json["transitions"] as! [String: [String: Int]]
let isHan = { (s: String) in !s.isEmpty && s.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }
let pairs = transitions
    .flatMap { previous, nexts in nexts.map { Pair(previous: previous, next: $0.key, count: $0.value) } }
    .filter { isHan($0.previous) && isHan($0.next) }
    .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.previous, $0.next) < ($1.previous, $1.next) }

// 考題：出現 2 次以上、前詞至少 2 個字（單字前詞資訊太少）；固定間隔抽樣，每次跑都一樣
let pool = pairs.filter { $0.count >= 2 && $0.previous.count >= 2 }
let tests = stride(from: 0, to: pool.count, by: max(1, pool.count / 30)).prefix(30).map { pool[$0] }

let baseInstructions = """
你是台灣繁體中文輸入法。使用者剛打完一段文字，請把它自然地接下去，\
像同一個人繼續打字。只輸出接下去的部分（不要重複原文），10 個字以內，\
用台灣繁體中文與台灣用語，不要解釋。
"""
let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
let clock = ContinuousClock()
func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

func ask(_ instructions: String, _ text: String) async throws -> (String, Int) {
    let session = LanguageModelSession(instructions: instructions)
    session.prewarm()
    try await Task.sleep(for: .milliseconds(300))
    let start = clock.now
    do {
        let out = try await session.respond(to: text, options: options).content
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), ms(clock.now - start))
    } catch {
        return ("（錯誤：\(error)）", ms(clock.now - start))
    }
}

/// 猜中：接續的開頭 8 個字裡出現正確的後詞
func hit(_ output: String, _ answer: String) -> Bool { output.prefix(8).contains(answer) }

_ = try await ask(baseInstructions, "你好")  // 暖機
var scores = (plain: 0, sheet: 0, lookup: 0)
var times = (plain: [Int](), sheet: [Int]())

for test in tests {
    let others = pairs.filter { $0 != test }
    // 小抄：最常用的 60 組＋同一個前詞的其他接法（都不含考題本身）
    let related = others.filter { $0.previous == test.previous }
    let sheet = Array(NSOrderedSet(array: related + others.prefix(60))) as! [Pair]
    let sheetText = sheet.map { "\($0.previous)→\($0.next)" }.joined(separator: "、")
    let sheetInstructions = baseInstructions + "\n這個人平常的用詞習慣（前詞→後詞）：\(sheetText)"

    let (plain, plainTime) = try await ask(baseInstructions, test.previous)
    let (withSheet, sheetTime) = try await ask(sheetInstructions, test.previous)
    let lookup = related.max { $0.count < $1.count }?.next ?? "（沒資料）"

    times.plain.append(plainTime); times.sheet.append(sheetTime)
    if hit(plain, test.next) { scores.plain += 1 }
    if hit(withSheet, test.next) { scores.sheet += 1 }
    if lookup == test.next { scores.lookup += 1 }
    print("\(test.previous)→【\(test.next)】｜無小抄：\(plain)｜有小抄：\(withSheet)｜查表：\(lookup)")
}

func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }
print("""

考題 \(tests.count) 題（從 \(pool.count) 組裡抽）
AI 無小抄：猜中 \(scores.plain) 題，延遲中位數 \(median(times.plain)) ms
AI 有小抄：猜中 \(scores.sheet) 題，延遲中位數 \(median(times.sheet)) ms
只查表　：猜中 \(scores.lookup) 題，幾乎 0 ms
""")
