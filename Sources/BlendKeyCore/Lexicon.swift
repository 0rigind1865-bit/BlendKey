import Foundation

/// 詞庫單元：一個讀音底下的候選詞與分數（ln 機率，越大越常見）
public struct Unigram: Equatable, Sendable {
    public let value: String
    public let score: Double

    public init(value: String, score: Double) {
        self.value = value
        self.score = score
    }
}

/// 詞庫：data.txt 格式（`讀音 詞 分數`，讀音的音節以 - 連接）。
/// 載入後唯讀，可跨執行緒共享。
public final class Lexicon: Sendable {
    private let map: [String: [Unigram]]
    /// 詞庫中最長的詞（音節數），詞圖搜尋的跨距上限
    public let maxSpan: Int

    public init(dataText: String) {
        var building: [String: [Unigram]] = [:]
        var span = 1
        for line in dataText.split(separator: "\n") {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ")
            guard fields.count == 3, let score = Double(fields[2]) else { continue }
            let reading = String(fields[0])
            building[reading, default: []].append(Unigram(value: String(fields[1]), score: score))
            let syllables = 1 + reading.count(where: { $0 == "-" })
            if syllables > span { span = syllables }
        }
        for key in building.keys where building[key]!.count > 1 {
            building[key]!.sort { $0.score > $1.score }
        }
        map = building
        maxSpan = span
    }

    public convenience init(contentsOf url: URL) throws {
        self.init(dataText: try String(contentsOf: url, encoding: .utf8))
    }

    /// 依分數由高到低
    public func unigrams(_ reading: String) -> [Unigram] {
        map[reading] ?? []
    }

    public var entryCount: Int {
        map.values.reduce(0) { $0 + $1.count }
    }
}
