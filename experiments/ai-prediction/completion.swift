// 實驗 E：「AI 補句」——打到一半，AI 用灰字補完這句話的後半段（inline completion）。
// 考題：Tests/Fixtures/sentences.tsv 的 90 句，只給前半段，比對 AI 補的和真正的後半段。
// 重點指標是「開頭猜對幾個字」：灰字只要前面對，使用者就會接受。
// 編譯：swiftc -O completion.swift -o /tmp/completion && /tmp/completion ../../Tests/Fixtures/sentences.tsv
import Foundation
import FoundationModels

let path = CommandLine.arguments.dropFirst().first ?? "../../Tests/Fixtures/sentences.tsv"
let sentences = try String(contentsOfFile: path, encoding: .utf8)
    .split(separator: "\n")
    .compactMap { $0.split(separator: "\t").last.map(String.init) }
    .filter { $0.count >= 6 }

let prompts: [(name: String, instructions: String)] = [
    ("接下去", """
    你是台灣繁體中文輸入法。使用者剛打完一段文字，請把它自然地接下去，\
    像同一個人繼續打字。只輸出接下去的部分（不要重複原文），10 個字以內，\
    用台灣繁體中文與台灣用語，不要解釋。
    """),
    ("補後半句", """
    下面是某人正在打的一句話的前半段（還沒打完）。請直接輸出這句話剩下的後半段，\
    到這句話結束為止。不要重複前半段、不要加標點、不要回應或解釋，你不是在跟他對話。\
    用台灣繁體中文與台灣用語。
    """),
]
let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
let clock = ContinuousClock()
func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

/// 模型常把前半段重打一遍、或加標點：清掉再比
func clean(_ output: String, given: String) -> String {
    var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(given) { text.removeFirst(given.count) }
    return String(text.filter { !"，。！？、：；「」…\"'.,!? ".contains($0) })
}

func commonPrefix(_ a: String, _ b: String) -> Int {
    zip(a, b).prefix { $0 == $1 }.count
}

_ = try await LanguageModelSession().respond(to: "你好", options: options)  // 暖機

for prompt in prompts {
    var firstTokenTimes: [Int] = [], totalTimes: [Int] = []
    var prefixChars = 0, atLeast2 = 0, exact = 0
    var samples: [String] = []
    var blocked: [String] = []
    for sentence in sentences {
        let cut = sentence.count / 2
        let given = String(sentence.prefix(cut))
        let truth = String(sentence.dropFirst(cut).filter { !"，。！？".contains($0) })

        let session = LanguageModelSession(instructions: prompt.instructions)
        session.prewarm()
        try await Task.sleep(for: .milliseconds(200))
        let start = clock.now
        var firstToken: Int?
        var raw = ""
        do {
            for try await snapshot in session.streamResponse(to: given, options: options) {
                raw = snapshot.content
                if firstToken == nil, !raw.isEmpty { firstToken = ms(clock.now - start) }
            }
        } catch {
            // Apple 的安全過濾（guardrailViolation）等：輸入法裡就是「這次不補」
            blocked.append("\(given)（\(error)".prefix(60) + "）")
            continue
        }
        totalTimes.append(ms(clock.now - start))
        firstTokenTimes.append(firstToken ?? ms(clock.now - start))

        let guess = clean(raw, given: given)
        let correct = commonPrefix(guess, truth)
        prefixChars += correct
        if correct >= 2 { atLeast2 += 1 }
        if guess == truth { exact += 1 }
        if samples.count < 12 || correct >= truth.count {
            samples.append("\(given)【\(truth)】→ \(guess)（對 \(correct) 字）")
        }
    }
    func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }
    let n = sentences.count
    print("=== 問法：\(prompt.name)（\(n) 句）===")
    samples.prefix(20).forEach { print($0) }
    print("""
    開頭平均猜對 \(String(format: "%.2f", Double(prefixChars) / Double(n))) 字
    開頭至少對 2 字：\(atLeast2)/\(n)（\(atLeast2 * 100 / n)%）
    整段完全一樣：\(exact)/\(n)（\(exact * 100 / n)%）
    被擋下（不補）：\(blocked.count)/\(n)　\(blocked.joined(separator: "、"))
    灰字開始出現：中位數 \(median(firstTokenTimes)) ms　整段寫完：中位數 \(median(totalTimes)) ms

    """)
}
