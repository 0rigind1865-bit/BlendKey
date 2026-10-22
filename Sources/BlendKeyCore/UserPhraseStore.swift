import Foundation

/// 使用者選字學習：
/// 1. 選字權重——「這個讀音你選過哪個字／詞、選過幾次」，影響排序與組句
/// 2. 自動造詞——一串音節被逐字改字後上屏，就升格為使用者新詞（蘋果注音也是一次就記）
/// JSON 存於 Application Support；可自動遷移第一版（純選字權重）格式。
public final class UserPhraseStore {

    private struct StoredData: Codable {
        var selections: [String: [String: Int]] = [:]    // 讀音 → 詞 → 選字次數
        var words: [String: [String: Int]] = [:]         // 已升格的使用者詞
        var transitions: [String: [String: Int]] = [:]   // 前詞 → 後詞 → 次數（連續文本語料）
        var contextSelections: [String: [String: Int]] = [:]  // 「前詞→讀音」 → 字 → 次數（單字選字只記這裡）

        init() {}

        /// 手寫解碼：舊版檔案缺的欄位當空的，不要整份解碼失敗（自動產生的 Codable 不吃預設值）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 一個認得的欄位都沒有＝第一版格式（讀音當 key），交給 legacy 解碼
            guard !c.allKeys.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "不是新版格式"))
            }
            selections = try c.decodeIfPresent(Table.self, forKey: .selections) ?? [:]
            words = try c.decodeIfPresent(Table.self, forKey: .words) ?? [:]
            transitions = try c.decodeIfPresent(Table.self, forKey: .transitions) ?? [:]
            contextSelections = try c.decodeIfPresent(Table.self, forKey: .contextSelections) ?? [:]
        }
        private typealias Table = [String: [String: Int]]
    }

    private var data = StoredData()
    private let fileURL: URL?
    /// ponytail: 使用者詞固定分數 -8（約當常用詞），穩贏單字拆解路徑；不夠再改動態
    private let userWordScore = -8.0
    /// ponytail: 詞對上限 20,000，超過就丟掉只出現一次的；不夠再改 LRU
    private let transitionLimit = 20_000

    /// 預設存放位置（輸入法與學習資料視窗共用）
    public static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlendKey/userphrases.json")
    }

    /// - Parameter fileURL: nil 表示純記憶體（測試、CLI 用）
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let raw = try? Data(contentsOf: fileURL) else { return }
        if let stored = try? JSONDecoder().decode(StoredData.self, from: raw) {
            data = stored
        } else if let legacy = try? JSONDecoder().decode([String: [String: Int]].self, from: raw) {
            data.selections = legacy  // 第一版格式只有選字權重
        } else {
            // 看不懂的檔案先改名留底，免得下次存檔用空資料蓋掉
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
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

    /// 帶前文的選字：單字只記在「前詞→讀音」底下（善解實測全域學「我試」會害「我是」全壞——
    /// 是／試、在／再這類同音單字，前文才分得出來）；多字詞歧義少，照舊記全域。
    /// `previous` 是組字區裡前一個詞的值；句首用游標前已上屏的前文，什麼都沒有就 "^"。
    /// ponytail: key 用「→」接，前詞含「→」會混（符號表能打出來）；真撞到再換分隔
    public func bump(reading: String, value: String, after previous: String) {
        guard value.count == 1 else { return bump(reading: reading, value: value) }
        data.contextSelections[Self.contextKey(previous, reading), default: [:]][value, default: 0] += 1
        save()
    }

    /// 這個前文底下選過這個字幾次的加分；沒選過回 0
    public func selectionBonus(after previous: String, reading: String, value: String) -> Double {
        guard let weight = data.contextSelections[Self.contextKey(previous, reading)]?[value], weight > 0 else { return 0 }
        return 2.0 * Foundation.log(1.0 + Double(weight))
    }

    /// Shift＋退格：使用者說這個字選錯了——把它在這個前文與全域的選字紀錄、自造詞、詞對都忘掉
    public func forget(reading: String, value: String, after previous: String) {
        data.contextSelections[Self.contextKey(previous, reading)]?[value] = nil
        data.selections[reading]?[value] = nil
        data.words[reading]?[value] = nil
        data.transitions[previous]?[value] = nil
        save()
    }

    static func contextKey(_ previous: String, _ reading: String) -> String { previous + "→" + reading }

    // MARK: - 自動造詞

    /// 上屏時回報一段「被改字的連續單字串」，一次就升格為使用者詞
    /// （守門是「必須有改字」，不是每次上屏都學：善解量過後者會學進三成碎片）
    public func noteWordCandidate(reading: String, value: String) {
        data.words[reading, default: [:]][value, default: 0] += 1
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

    /// 聯想詞：這個詞後面最常接的詞（次數多的在前）。
    /// ponytail: 只收出現 2 次以上的，一次性的組合多半是雜訊；嫌少再放寬
    public func nextWords(after previous: String, limit: Int) -> [String] {
        (data.transitions[previous] ?? [:])
            .filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    public var transitionCount: Int {
        data.transitions.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - 檢視與逐筆管理

    /// 一筆學習紀錄（供檢視視窗顯示）
    public struct Entry: Identifiable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case selection = "選字紀錄"
            case contextSelection = "前文選字"
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
        case .contextSelection: source = data.contextSelections
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
        case .contextSelection: data.contextSelections[entry.key]?[entry.value] = nil
        case .word: data.words[entry.key]?[entry.value] = nil
        case .transition: data.transitions[entry.key]?[entry.value] = nil
        }
        save()
    }

    /// 清除全部學習資料（偏好設定用）
    public func reset() {
        data = StoredData()
        flush()  // 使用者按了清除：立刻生效
    }

    private func pruneTransitionsIfNeeded() {
        guard transitionCount > transitionLimit else { return }
        for (previous, nexts) in data.transitions {
            let kept = nexts.filter { $0.value > 1 }
            data.transitions[previous] = kept.isEmpty ? nil : kept
        }
    }

    /// 停手多久才寫檔：連打時每上屏一次就編碼整份 JSON（詞對滿額近 1 MB）會卡主執行緒
    private let saveDelay: TimeInterval = 1.5
    private var pendingSave: DispatchWorkItem?

    /// 延後合併寫檔：連續變動只在停手後寫一次（假設只在主執行緒使用）
    private func save() {
        guard fileURL != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// 立刻寫檔：行程結束前、測試重載前呼叫
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}
