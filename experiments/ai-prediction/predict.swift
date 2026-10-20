// 實驗：用 Apple 內建本機模型（FoundationModels）做聯想詞。
// 編譯：swiftc -O predict.swift -o /tmp/predict && /tmp/predict
// 只在本機跑，不連網。不屬於輸入法本體。
import Foundation
import FoundationModels

let options = GenerationOptions(sampling: .greedy)

// 只有 CommandLineTools 時沒有 @Generable 巨集外掛，改用執行期建構的格式（效果相同）
let schema = try GenerationSchema(
    root: DynamicGenerationSchema(name: "Prediction", properties: [
        DynamicGenerationSchema.Property(
            name: "words",
            description: "接下來最可能接著打的詞，每個 1 到 4 個字，台灣繁體中文",
            schema: DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(type: String.self),
                minimumElements: 5, maximumElements: 5
            )
        ),
    ]),
    dependencies: []
)

func predict(_ session: LanguageModelSession, _ text: String) async throws -> [String] {
    let response = try await session.respond(to: "使用者打了：\(text)", schema: schema, options: options)
    return try response.content.value([String].self, forProperty: "words")
}

let instructions = """
你是台灣繁體中文輸入法的聯想詞引擎。使用者剛打完一段文字，\
請預測他接下來最可能接著打的詞。只用台灣繁體中文與台灣用語，\
不要標點符號，不要重複使用者已經打的字，不要整句。
"""

let openings = [
    "麻煩你幫我確認一下", "明天的彩排", "這批貨", "燈光的部分", "音響已經",
    "模型列印到一半", "這個程式", "客人問說", "薪水下週", "請假",
    "報價單", "演唱會當天", "我等一下", "謝謝你的", "不好意思",
    "線材記得", "進場時間是", "蝦皮訂單", "下午三點", "這個問題",
]

/// 有沒有簡體字：轉成繁體後內容會變（少數一簡對多繁的字可能誤判，夠當實驗用）
func hasSimplified(_ text: String) -> Bool {
    text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) != text
}

func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

let clock = ContinuousClock()

// 1. 冷啟動：第一次呼叫（含模型載入）
var start = clock.now
let cold = try await predict(LanguageModelSession(instructions: instructions), openings[0])
print("冷啟動 \(ms(clock.now - start)) ms：\(openings[0]) → \(cold)")

// 2. 每句一個新 session（不讓上一句的內容影響下一句），先 prewarm 再量
var latencies: [Int] = []
var simplifiedCount = 0
for opening in openings {
    let session = LanguageModelSession(instructions: instructions)
    session.prewarm()
    try await Task.sleep(for: .milliseconds(300))  // 模擬「使用者還在打字」的空檔
    start = clock.now
    let words = try await predict(session, opening)
    let elapsed = ms(clock.now - start)
    latencies.append(elapsed)
    let flag = words.contains(where: hasSimplified) ? "  ⚠️有簡體" : ""
    if !flag.isEmpty { simplifiedCount += 1 }
    print("\(elapsed) ms　\(opening) → \(words.joined(separator: "／"))\(flag)")
}

let sorted = latencies.sorted()
print("\n延遲：中位數 \(sorted[sorted.count / 2]) ms、最快 \(sorted.first!) ms、最慢 \(sorted.last!) ms")
print("混到簡體：\(simplifiedCount)/\(openings.count) 句")
