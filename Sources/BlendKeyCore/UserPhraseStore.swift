import Foundation

/// 使用者選字學習：
/// 1. 選字權重——「這個讀音你選過哪個字／詞、選過幾次」，影響排序與組句
/// 2. 自動造詞——同一串音節連續兩次被改字後上屏，升格為使用者新詞
/// JSON 存於 Application Support；可自動遷移第一版（純選字權重）格式。
public final class UserPhraseStore {

    private struct StoredData: Codable {
        var selections: [String: [String: Int]] = [:]    // 讀音 → 詞 → 選字次數
        var pendingWords: [String: [String: Int]] = [:]  // 造詞候補（出現 1 次）
        var words: [String: [String: Int]] = [:]         // 已升格的使用者詞
    }

    private var data = StoredData()
    private let fileURL: URL?
    /// ponytail: 使用者詞固定分數 -8（約當常用詞），穩贏單字拆解路徑；不夠再改動態
    private let userWordScore = -8.0
    private let promotionThreshold = 2

    /// - Parameter fileURL: nil 表示純記憶體（測試、CLI 用）
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let raw = try? Data(contentsOf: fileURL) else { return }
        if let stored = try? JSONDecoder().decode(StoredData.self, from: raw) {
            data = stored
        } else if let legacy = try? JSONDecoder().decode([String: [String: Int]].self, from: raw) {
            data.selections = legacy  // 第一版格式只有選字權重
        }
    }

    // MARK: - 選字權重

    public func bump(reading: String, value: String) {
        data.selections[reading, default: [:]][value, default: 0] += 1
        save()
    }

    /// 加到 unigram 分數上的學習權重（選越多次越大，對數成長）
    public func bonus(reading: String, value: String) -> Double {
        guard let weight = data.selections[reading]?[value], weight > 0 else { return 0 }
        return 2.0 * Foundation.log(1.0 + Double(weight))
    }

    // MARK: - 自動造詞

    /// 上屏時回報一段「被改字的連續單字串」；出現第二次即升格為使用者詞
    public func noteWordCandidate(reading: String, value: String) {
        if data.words[reading]?[value] != nil {
            data.words[reading]![value]! += 1  // 已是使用者詞：記次數即可
            save()
            return
        }
        let count = (data.pendingWords[reading]?[value] ?? 0) + 1
        if count >= promotionThreshold {
            data.pendingWords[reading]?[value] = nil
            data.words[reading, default: [:]][value] = count
        } else {
            data.pendingWords[reading, default: [:]][value] = count
        }
        save()
    }

    /// 這個讀音底下已學成的使用者詞
    public func userWords(reading: String) -> [Unigram] {
        (data.words[reading] ?? [:]).keys.map { Unigram(value: $0, score: userWordScore) }
    }

    private func save() {
        // ponytail: 每次變動直接寫檔（檔案很小）；量大再改批次
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}
