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

    public init(start: Int, length: Int, value: String, reading: String?) {
        self.start = start
        self.length = length
        self.value = value
        self.reading = reading
    }

    public var end: Int { start + length }
}

/// 整句解碼：音節串 → 詞圖 → 最佳路徑（unigram 分數 DP）。
/// pin（使用者指定的候選）強制走過，等長重疊的其他節點一律跳過。
public struct SentenceDecoder {
    private let lexicon: Lexicon
    /// 使用者學習加權：(讀音, 詞) → 額外分數
    public var scoreBonus: ((String, String) -> Double)?
    /// 未知讀音（詞庫查不到的單音節）的懲罰分數
    private let unknownPenalty = -17.0
    /// ponytail: 每節點固定罰分，偏好長詞路徑；斷詞品質不夠再升級 bigram
    private let nodePenalty = -0.5

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    private func adjusted(_ unigram: Unigram, reading: String) -> Double {
        unigram.score + (scoreBonus?(reading, unigram.value) ?? 0)
    }

    public func walk(_ elements: [Element], pins: [DecodedSegment] = []) -> [DecodedSegment] {
        let n = elements.count
        guard n > 0 else { return [] }

        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [DecodedSegment?](repeating: nil, count: n + 1)
        best[0] = 0

        func conflictsWithPin(start: Int, end: Int) -> Bool {
            pins.contains { pin in
                pin.start < end && start < pin.end && !(pin.start == start && pin.end == end)
            }
        }

        for end in 1...n {
            let earliest = max(0, end - lexicon.maxSpan)
            for start in earliest..<end {
                guard !conflictsWithPin(start: start, end: end) else { continue }
                for node in nodes(elements, start: start, end: end, pins: pins) {
                    let score = best[start] + node.score + nodePenalty
                    if score > best[end] {
                        best[end] = score
                        back[end] = node.segment
                    }
                }
            }
        }

        var result: [DecodedSegment] = []
        var cursor = n
        while cursor > 0, let segment = back[cursor] {
            result.append(segment)
            cursor = segment.start
        }
        return result.reversed()
    }

    /// 候選字窗用：從 start 起所有跨距的候選，長詞在前、同長依分數（含學習加權）
    public func candidateSegments(_ elements: [Element], start: Int) -> [DecodedSegment] {
        var segments: [DecodedSegment] = []
        for length in stride(from: min(elements.count - start, lexicon.maxSpan), through: 1, by: -1) {
            guard let reading = joinedReading(elements, start: start, end: start + length) else { continue }
            let ranked = lexicon.unigrams(reading)
                .sorted { adjusted($0, reading: reading) > adjusted($1, reading: reading) }
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
        let unigrams = lexicon.unigrams(reading)
        if let top = unigrams.max(by: { adjusted($0, reading: reading) < adjusted($1, reading: reading) }) {
            return [Node(
                segment: DecodedSegment(start: start, length: length, value: top.value, reading: reading),
                score: adjusted(top, reading: reading)
            )]
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
