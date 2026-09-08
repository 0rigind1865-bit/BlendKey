/// 相似音（模糊音）：台灣人常混淆的注音對，開啟後打錯也找得到字。
/// 例如打 ㄗㄨㄥ 也能找到「中」（ㄓㄨㄥ）、打 ㄧㄣ 也能找到「應」（ㄧㄥ）。
public enum FuzzyReading {

    /// 每一組都是雙向互換
    private static let pairs: [(Character, Character)] = [
        ("ㄓ", "ㄗ"), ("ㄔ", "ㄘ"), ("ㄕ", "ㄙ"),  // 捲舌／不捲舌
        ("ㄌ", "ㄋ"),                              // ㄌㄋ 不分
        ("ㄈ", "ㄏ"),                              // ㄈㄏ 不分（少數地區）
        ("ㄣ", "ㄥ"), ("ㄢ", "ㄤ"),                // 前鼻音／後鼻音
    ]

    private static let swap: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (a, b) in pairs {
            table[a] = b
            table[b] = a
        }
        return table
    }()

    /// 產生一個讀音（可含 - 連接的多音節）的所有相似音變體，不含原讀音。
    /// 多音節時會做組合，上限避免爆炸（4 音節各 2 個模糊位就有 16 種）。
    public static func variants(of reading: String, limit: Int = 16) -> [String] {
        // 找出所有可替換的位置
        let chars = Array(reading)
        let positions = chars.indices.filter { swap[chars[$0]] != nil }
        guard !positions.isEmpty else { return [] }

        var results: [String] = []
        // 每個位置替換或不替換，遍歷所有組合（跳過全不替換的那一組）
        let combos = 1 << positions.count
        for mask in 1..<combos {
            var variant = chars
            for (bit, position) in positions.enumerated() where mask & (1 << bit) != 0 {
                variant[position] = swap[chars[position]]!
            }
            results.append(String(variant))
            if results.count >= limit { break }
        }
        return results
    }
}
