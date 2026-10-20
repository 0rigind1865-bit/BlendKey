// 實驗 F：「AI 校正」——組字結果可能有同音錯字（打的字→打的自），請 AI 改正。
// 保險：AI 改的每個字都必須和該位置的注音同音（詞庫查得到），否則整句不採用。
// 和融鍵的解碼器一起編譯（不安裝輸入法也能跑）：
//   swiftc -O -parse-as-library correction.swift ../../Sources/BlendKeyCore/*.swift -o /tmp/correction
//   /tmp/correction ../../Resources/data/data.txt ../../Tests/Fixtures/sentences.tsv
import Foundation
import FoundationModels

@main
struct CorrectionExperiment {
    static func main() async throws {
        let args = CommandLine.arguments
        let lexicon = try Lexicon(contentsOf: URL(fileURLWithPath: args[1]))
        let decoder = SentenceDecoder(lexicon: lexicon)
        let rows: [(readings: [String], truth: String)] = try String(contentsOfFile: args[2], encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t")
                guard parts.count == 2 else { return nil }
                return (parts[0].split(separator: "-").map(String.init), String(parts[1]))
            }

        /// 這個字在這個注音底下查得到嗎（同音保險）
        func sameSound(_ ch: Character, _ reading: String) -> Bool {
            lexicon.unigrams(reading).contains { $0.value == String(ch) }
        }
        /// 逐字合併：字數一樣時，只採用「同音」的改動，其他字維持原樣（AI 順手亂改的不理）
        func merge(_ output: String, decoded: String, readings: [String]) -> String? {
            let out = Array(output), old = Array(decoded)
            guard out.count == old.count, out.count == readings.count else { return nil }
            return String(zip(zip(out, old), readings).map { pair, reading in
                pair.0 != pair.1 && sameSound(pair.0, reading) ? pair.0 : pair.1
            })
        }
        /// AI 的輸出合格嗎：字數不變，改過的字都同音
        func valid(_ output: String, decoded: String, readings: [String]) -> Bool {
            let out = Array(output), old = Array(decoded)
            guard out.count == old.count, out.count == readings.count else { return false }
            return zip(zip(out, old), readings).allSatisfy { pair, reading in
                pair.0 == pair.1 || sameSound(pair.0, reading)
            }
        }

        let promptA = """
        下面是用注音輸入法打出來的一句台灣繁體中文，可能有選錯的同音字。\
        請輸出改正後的整句：只能把字換成同音字，字數不能變，不要加標點，不要解釋。\
        如果沒有錯就原樣輸出。
        """
        let promptB = """
        下面是用注音輸入法打出來的一句台灣繁體中文。每個詞後面的［］是同音的其他選擇。\
        請選出最通順、最合理的組合，輸出整句（不含［］），字數不能變，不要解釋。\
        如果原本的就對就原樣輸出。
        """
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 60)
        let clock = ContinuousClock()

        let mergeMode = args.contains("--merge")
        for (name, instructions, withChoices) in [("A 直接改", promptA, false)] {
            var fixed = 0, broken = 0, stillWrong = 0, keptRight = 0, rejected = 0, blocked = 0
            var times: [Int] = []
            var notes: [String] = []
            for row in rows {
                let elements = row.readings.map { Element.reading($0) }
                let walked = decoder.walk(elements)
                let decoded = walked.map(\.value).joined()
                var prompt = decoded
                if withChoices {
                    prompt = walked.map { segment in
                        let others = decoder.candidateSegments(elements, start: segment.start)
                            .filter { $0.length == segment.length && $0.value != segment.value }
                            .prefix(3).map(\.value)
                        return others.isEmpty ? segment.value : "\(segment.value)［\(others.joined(separator: "／"))］"
                    }.joined()
                }

                let session = LanguageModelSession(instructions: instructions)
                let start = clock.now
                var output = decoded
                do {
                    let raw = try await session.respond(to: prompt, options: options).content
                    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        .filter { !"，。！？、 「」［］".contains($0) }
                    if mergeMode, let merged = merge(cleaned, decoded: decoded, readings: row.readings) {
                        output = merged
                        if merged != cleaned { notes.append("　（逐字合併：AI 寫「\(cleaned)」，只採用同音的改動）") }
                    } else if valid(cleaned, decoded: decoded, readings: row.readings) {
                        output = cleaned
                    } else {
                        rejected += 1  // 不同音或字數不對：不採用，維持原句
                        notes.append("　（被擋：AI 寫「\(cleaned)」）")
                    }
                } catch {
                    blocked += 1
                }
                let elapsed = clock.now - start
                times.append(Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))

                let wasRight = decoded == row.truth, isRight = output == row.truth
                switch (wasRight, isRight) {
                case (false, true): fixed += 1; notes.append("✅ 修好：\(decoded) → \(output)")
                case (true, false): broken += 1; notes.append("❌ 改壞：\(decoded) → \(output)")
                case (false, false): stillWrong += 1; notes.append("・沒修好：\(decoded) → \(output)（應為 \(row.truth)）")
                case (true, true): keptRight += 1
                }
            }
            let sorted = times.sorted()
            print("=== 問法 \(name)（\(rows.count) 句）===")
            notes.forEach { print($0) }
            print("""
            原本錯的 \(fixed + stillWrong) 句：修好 \(fixed)、沒修好 \(stillWrong)
            原本對的 \(keptRight + broken) 句：維持 \(keptRight)、改壞 \(broken)
            AI 輸出不合格被擋（不同音／字數不對）：\(rejected)　被安全過濾擋：\(blocked)
            整句正確：\(keptRight + fixed)/\(rows.count)（原本 \(keptRight + broken)/\(rows.count)）
            延遲中位數 \(sorted[sorted.count / 2]) ms

            """)
        }
    }
}
