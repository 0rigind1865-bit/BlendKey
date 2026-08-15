import Foundation

/// 英文詞偵測：載入詞表（預設 /usr/share/dict/words，公有領域）後以二分搜尋查詞。
/// 供「打了一串不像注音的鍵」時提供英文候選。
public final class EnglishDetector: Sendable {
    private let words: [String]  // 小寫、排序、去重

    public init(words rawWords: [String]) {
        var normalized = rawWords.map { $0.lowercased() }
        normalized.sort()
        var deduped: [String] = []
        deduped.reserveCapacity(normalized.count)
        for word in normalized where word != deduped.last {
            deduped.append(word)
        }
        words = deduped
    }

    public convenience init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(words: text.split(separator: "\n").map(String.init))
    }

    public func isWord(_ candidate: String) -> Bool {
        let target = candidate.lowercased()
        var low = 0
        var high = words.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if words[mid] == target { return true }
            if words[mid] < target { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }
}
