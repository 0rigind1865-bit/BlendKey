import Foundation

/// 使用者選字學習：記住「這個讀音你選過哪個字／詞、選過幾次」，
/// 讓下次組句與候選排序偏向你的習慣。JSON 存於 Application Support。
public final class UserPhraseStore {
    private var weights: [String: [String: Int]]  // 讀音 → 詞 → 次數
    private let fileURL: URL?

    /// - Parameter fileURL: nil 表示純記憶體（測試用）
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            weights = loaded
        } else {
            weights = [:]
        }
    }

    public func bump(reading: String, value: String) {
        weights[reading, default: [:]][value, default: 0] += 1
        save()
    }

    /// 加到 unigram 分數上的學習權重（選越多次越大，對數成長）
    public func bonus(reading: String, value: String) -> Double {
        guard let weight = weights[reading]?[value], weight > 0 else { return 0 }
        return 2.0 * Foundation.log(1.0 + Double(weight))
    }

    private func save() {
        // ponytail: 每次選字直接寫檔（檔案很小）；量大再改批次
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(weights) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
