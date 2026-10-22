/// 組字區元素：一個已完成的注音音節，或一段直出文字（英文、標點）。
public enum Element: Equatable, Sendable {
    case reading(String)  // canonical 注音（含調號），如 "ㄋㄧˇ"
    case literal(String)  // 直出片段，原樣上屏

    public var readingValue: String? {
        if case .reading(let r) = self { return r }
        return nil
    }
}

/// 詞圖上走出來的一段：elements[start..<start+length] 對應的詞
public struct DecodedSegment: Equatable, Sendable {
    public let start: Int
    public let length: Int
    public let value: String
    public let reading: String?  // literal 段為 nil
    /// 固定來自 AI 校正的 pin 不算使用者自己改字，上屏時不學成造詞
    public var fromAI = false

    public init(start: Int, length: Int, value: String, reading: String?, fromAI: Bool = false) {
        self.start = start
        self.length = length
        self.value = value
        self.reading = reading
        self.fromAI = fromAI
    }

    func shifted(by delta: Int) -> DecodedSegment {
        DecodedSegment(start: start + delta, length: length, value: value, reading: reading, fromAI: fromAI)
    }

    public var end: Int { start + length }
}

/// 整句解碼：音節串 → 詞圖 → 最佳路徑（unigram 分數 DP）。
/// pin（使用者指定的候選）強制走過，等長重疊的其他節點一律跳過。
public struct SentenceDecoder {
    private let lexicon: Lexicon
    /// 使用者學習加權：(讀音, 詞) → 額外分數
    public var scoreBonus: ((String, String) -> Double)?
    /// 使用者自造詞：讀音 → 額外候選（與內建詞庫合流）
    public var extraUnigrams: ((String) -> [Unigram])?
    /// 使用者語料的詞對加分：(前詞, 後詞) → 加分（沒打過就 0）
    public var transitionBonus: ((String, String) -> Double)?
    /// 詞對加分的權重：2.0 由 --eval --train 掃描而得
    /// （同句打 1 次 87%、3 次 96%；未學過的句子完全不受影響）
    public var transitionWeight = 2.0
    /// 游標前已上屏文字的結尾（最多 2 個漢字，由 InputEngine 截好）：第一個詞的詞對加分條件。
    /// 先送出「好」再打 ㄅㄚ˙ 時，第一個詞不再當成句首算，「吧」才贏得過「巴」。空字串＝句首
    public var leftContext = ""
    /// 帶前文的選字加分（前詞, 讀音, 值）：單字選字只在同樣前文底下生效
    public var selectionBonus: ((String, String, String) -> Double)?
    /// 每個跨距取幾個候選進詞圖：>1 才讓上下文有選擇餘地
    public var candidateDepth = 4
    /// 相似音（ㄓㄗ、ㄕㄙ、ㄣㄥ…互通）：開啟後打錯也找得到字
    public var fuzzyEnabled = false
    /// 相似音候選的罰分：確保正確讀音永遠排在前面，只在沒有更好選擇時遞補
    private let fuzzyPenalty = -6.0
    /// 未知讀音（詞庫查不到的單音節）的懲罰分數
    private let unknownPenalty = -17.0
    /// 每節點固定罰分：偏好長詞路徑，補償 unigram 獨立性假設低估長詞的問題。
    /// −2.0 由 blendkey-cli --eval 對 90 句自然語句掃描而得（80%→83%）。
    /// ponytail: 從詞庫片語推的 char-bigram 實測會倒退（見 commit 說明），
    /// 真要再進一步需要連續文本語料的詞對統計。
    private let nodePenalty = -2.0

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    /// 詞圖搜尋跨距：至少留 6，使用者自造詞不受小詞庫的 maxSpan 限制
    private var searchSpan: Int { max(lexicon.maxSpan, 6) }

    private func adjusted(_ unigram: Unigram, reading: String) -> Double {
        unigram.score + (scoreBonus?(reading, unigram.value) ?? 0)
    }

    /// 內建詞庫＋使用者詞＋相似音變體合流，同值保留調整後分數較高者
    private func allUnigrams(_ reading: String) -> [Unigram] {
        let extras = extraUnigrams?(reading) ?? []
        guard fuzzyEnabled || !extras.isEmpty else { return lexicon.unigrams(reading) }
        var pool = lexicon.unigrams(reading) + extras
        if fuzzyEnabled {
            for variant in FuzzyReading.variants(of: reading) {
                pool += lexicon.unigrams(variant).map {
                    Unigram(value: $0.value, score: $0.score + fuzzyPenalty)
                }
            }
        }
        var best: [String: Unigram] = [:]
        for unigram in pool {
            if let current = best[unigram.value],
               adjusted(current, reading: reading) >= adjusted(unigram, reading: reading) {
                continue
            }
            best[unigram.value] = unigram
        }
        return best.values.sorted { $0.value < $1.value }  // 固定順序：同分時結果不隨 hash 種子變動
    }

    /// 詞圖上的一個狀態：以某位置結尾的節點，及走到它的最佳分數與回溯指標
    private struct State {
        let segment: DecodedSegment
        let score: Double
        let prevIndex: Int  // states[segment.start] 的索引；-1 代表句首
    }

    /// Viterbi：逐節點保留狀態，轉移時加上使用者語料的詞對加分
    public func walk(_ elements: [Element], pins: [DecodedSegment] = []) -> [DecodedSegment] {
        let n = elements.count
        guard n > 0 else { return [] }

        var states = [[State]](repeating: [], count: n + 1)

        func conflictsWithPin(start: Int, end: Int) -> Bool {
            pins.contains { pin in
                pin.start < end && start < pin.end && !(pin.start == start && pin.end == end)
            }
        }

        for end in 1...n {
            let earliest = max(0, end - searchSpan)
            for start in earliest..<end {
                guard start == 0 || !states[start].isEmpty else { continue }
                guard !conflictsWithPin(start: start, end: end) else { continue }
                for node in nodes(elements, start: start, end: end, pins: pins) {
                    let base = node.score + nodePenalty
                    if start == 0 {
                        let score = base + contextBonus(node.segment.value) + selectionBonus(after: startKey, node.segment)
                        states[end].append(State(segment: node.segment, score: score, prevIndex: -1))
                        continue
                    }
                    var bestScore = -Double.infinity
                    var bestPrev = -1
                    for (index, previous) in states[start].enumerated() {
                        let bonus = transitionBonus.map {
                            transitionWeight * $0(previous.segment.value, node.segment.value)
                        } ?? 0
                        let score = previous.score + base + bonus + selectionBonus(after: previous.segment.value, node.segment)
                        if score > bestScore {
                            bestScore = score
                            bestPrev = index
                        }
                    }
                    if bestPrev >= 0 {
                        states[end].append(State(segment: node.segment, score: bestScore, prevIndex: bestPrev))
                    }
                }
            }
        }

        var result: [DecodedSegment] = []
        var position = n
        var index = states[n].enumerated().max { $0.element.score < $1.element.score }?.offset ?? -1
        while position > 0, index >= 0 {
            let state = states[position][index]
            result.append(state.segment)
            position = state.segment.start
            index = state.prevIndex
        }
        return result.reversed()
    }

    /// 句首的前文 key：游標前的漢字，什麼都沒有就 "^"（真正的句首也是一種前文）
    public var startKey: String { leftContext.isEmpty ? "^" : leftContext }

    /// 前文選字加分：先試整個前詞，再試它的最後 1 字；都沒選過就 0
    private func selectionBonus(after previous: String, _ segment: DecodedSegment) -> Double {
        guard let selectionBonus, let reading = segment.reading else { return 0 }
        for key in [previous, String(previous.suffix(1))] where !key.isEmpty {
            let bonus = selectionBonus(key, reading, segment.value)
            if bonus > 0 { return bonus }
        }
        return 0
    }

    /// 前文→第一個詞的詞對加分：先試整段前文（2 字），再試最後 1 字；都沒打過就 0
    private func contextBonus(_ next: String) -> Double {
        guard let transitionBonus, !leftContext.isEmpty else { return 0 }
        for key in [leftContext, String(leftContext.suffix(1))] where !key.isEmpty {
            let bonus = transitionBonus(key, next)
            if bonus > 0 { return transitionWeight * bonus }
        }
        return 0
    }

    /// 候選字窗用：從 start 起所有跨距的候選，長詞在前、同長依分數（含學習加權）
    public func candidateSegments(_ elements: [Element], start: Int, after previous: String = "^") -> [DecodedSegment] {
        var segments: [DecodedSegment] = []
        for length in stride(from: min(elements.count - start, searchSpan), through: 1, by: -1) {
            guard let reading = joinedReading(elements, start: start, end: start + length) else { continue }
            func score(_ unigram: Unigram) -> Double {
                let segment = DecodedSegment(start: start, length: length, value: unigram.value, reading: reading)
                return adjusted(unigram, reading: reading) + selectionBonus(after: previous, segment)
            }
            let ranked = allUnigrams(reading).sorted { score($0) > score($1) }
            for unigram in ranked {
                segments.append(DecodedSegment(start: start, length: length, value: unigram.value, reading: reading))
            }
        }
        return segments
    }

    private struct Node {
        let segment: DecodedSegment
        let score: Double
    }

    private func nodes(_ elements: [Element], start: Int, end: Int, pins: [DecodedSegment]) -> [Node] {
        // pin 精確命中：只走 pin
        if let pin = pins.first(where: { $0.start == start && $0.end == end }) {
            return [Node(segment: pin, score: 0)]  // 使用者欽點，分數歸零（最高待遇）
        }
        let length = end - start
        if length == 1, case .literal(let text) = elements[start] {
            return [Node(segment: DecodedSegment(start: start, length: 1, value: text, reading: nil), score: -0.1)]
        }
        guard let reading = joinedReading(elements, start: start, end: end) else { return [] }
        let unigrams = allUnigrams(reading)
        if !unigrams.isEmpty {
            // 取前 K 名進詞圖：只留第一名的話，詞對加分沒有可選的對象
            let ranked = unigrams
                .sorted { adjusted($0, reading: reading) > adjusted($1, reading: reading) }
                .prefix(max(1, candidateDepth))
            return ranked.map { unigram in
                Node(
                    segment: DecodedSegment(start: start, length: length, value: unigram.value, reading: reading),
                    score: adjusted(unigram, reading: reading)
                )
            }
        }
        if length == 1 {
            // 詞庫沒有的讀音：原樣顯示注音，重罰但仍可通行
            return [Node(segment: DecodedSegment(start: start, length: 1, value: reading, reading: reading), score: unknownPenalty)]
        }
        return []
    }

    private func joinedReading(_ elements: [Element], start: Int, end: Int) -> String? {
        var parts: [String] = []
        for index in start..<end {
            guard let reading = elements[index].readingValue else { return nil }
            parts.append(reading)
        }
        return parts.joined(separator: "-")
    }
}
