// 實驗 B：不要求「5 個詞」，改請模型把句子自然接下去（語言模型最擅長的事），
// 取接下去的開頭當聯想。純文字輸出、限制長度，量速度與品質。
// 編譯：swiftc -O continue.swift -o /tmp/continue && /tmp/continue
import Foundation
import FoundationModels

let instructions = """
你是台灣繁體中文輸入法。使用者剛打完一段文字，請把它自然地接下去，\
像同一個人繼續打字。只輸出接下去的部分（不要重複原文），10 個字以內，\
用台灣繁體中文與台灣用語，不要解釋。
"""
// 試過加「文字接龍」說明＋3 個範例：反而常重複原文（請假｜請假一天），已放棄
let openings = [
    "麻煩你幫我確認一下", "明天的彩排", "這批貨", "燈光的部分", "音響已經",
    "模型列印到一半", "這個程式", "客人問說", "薪水下週", "請假",
    "報價單", "演唱會當天", "我等一下", "謝謝你的", "不好意思",
    "線材記得", "進場時間是", "蝦皮訂單", "下午三點", "這個問題",
]
let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
let clock = ContinuousClock()
func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

_ = try await LanguageModelSession(instructions: instructions).respond(to: "你好", options: options)  // 暖機
var latencies: [Int] = []
for opening in openings {
    let session = LanguageModelSession(instructions: instructions)
    session.prewarm()
    try await Task.sleep(for: .milliseconds(300))
    let start = clock.now
    let text = try await session.respond(to: opening, options: options).content
    let elapsed = ms(clock.now - start)
    latencies.append(elapsed)
    print("\(elapsed) ms　\(opening)｜\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
let sorted = latencies.sorted()
print("\n延遲：中位數 \(sorted[sorted.count / 2]) ms、最快 \(sorted.first!) ms、最慢 \(sorted.last!) ms")
