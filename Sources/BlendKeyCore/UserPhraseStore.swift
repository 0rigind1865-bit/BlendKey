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
        var transitions: [String: [String: Int]] = [:]   // 前詞 → 後詞 → 次數（連續文本語料）
    }

    private var data = StoredData()
    private let fileURL: URL?
    /// ponytail: 使用者詞固定分數 -8（約當常用詞），穩贏單字拆解路徑；不夠再改動態
    private let userWordScore = -8.0
    private let promotionThreshold = 2
    /// ponytail: 詞對上限 20,000，超過就丟掉只出現一次的；不夠再改 LRU
    private let transitionLimit = 20_000

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

    // MARK: - 連續文本語料（詞對）

    /// 上屏時記錄實際的詞序列：這是真正的連續文本語料，
    /// 與詞庫片語表不同——它含有真實的詞邊界，正是斷詞需要的上下文。
    /// 全程僅存在本機、只記詞對次數不留原句。
    public func noteCommit(_ words: [String]) {
        guard words.count >= 2 else { return }
        for (previous, next) in zip(words, words.dropFirst()) where !previous.isEmpty && !next.isEmpty {
            data.transitions[previous, default: [:]][next, default: 0] += 1
        }
        pruneTransitionsIfNeeded()
        save()
    }

    /// 「前詞之後接這個詞」的加分：只獎勵使用者真的打過的組合，
    /// 沒看過就回 0（退回純 unigram），所以不會像 PMI 那樣獎勵罕見雜訊。
    public func transitionBonus(from previous: String, to next: String) -> Double {
        guard let count = data.transitions[previous]?[next], count > 0 else { return 0 }
        return Foundation.log(1.0 + Double(count))
    }

    public var transitionCount: Int {
        data.transitions.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - 檢視與逐筆管理

    /// 一筆學習紀錄（供檢視視窗顯示）
    public struct Entry: Identifiable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case selection = "選字紀錄"
            case word = "自動造詞"
            case transition = "詞語接續"
        }
        public let kind: Kind
        public let key: String    // 讀音（選字／造詞）或前詞（接續）
        public let value: String  // 選的字詞或後詞
        public let count: Int
        public var id: String { "\(kind.rawValue)\t\(key)\t\(value)" }
    }

    public func entries(_ kind: Entry.Kind) -> [Entry] {
        let source: [String: [String: Int]]
        switch kind {
        case .selection: source = data.selections
        case .word: source = data.words
        case .transition: source = data.transitions
        }
        return source
            .flatMap { key, values in
                values.map { Entry(kind: kind, key: key, value: $0.key, count: $0.value) }
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    public func remove(_ entry: Entry) {
        switch entry.kind {
        case .selection: data.selections[entry.key]?[entry.value] = nil
        case .word: data.words[entry.key]?[entry.value] = nil
        case .transition: data.transitions[entry.key]?[entry.value] = nil
        }
        save()
    }

    /// 清除全部學習資料（偏好設定用）
    public func reset() {
        data = StoredData()
        save()
    }

    private func pruneTransitionsIfNeeded() {
        guard transitionCount > transitionLimit else { return }
        for (previous, nexts) in data.transitions {
            let kept = nexts.filter { $0.value > 1 }
            data.transitions[previous] = kept.isEmpty ? nil : kept
        }
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
