import Foundation

/// 快捷文字本：縮寫展開成長句（addr → 地址）。純文字檔，每行「縮寫 空白／Tab 展開內容」，
/// `#` 開頭是註解。打縮寫時展開內容排在中英並列窗第一位，空白或 Enter 送出；Tab 仍出縮寫本身。
public struct Shortcuts: Equatable, Sendable {
    private var entries: [String: String] = [:]

    public init() {}

    public init(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let abbreviation = trimmed[..<split].lowercased()
            let expansion = trimmed[split...].trimmingCharacters(in: .whitespaces)
            guard !expansion.isEmpty, abbreviation.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            entries[abbreviation] = expansion
        }
    }

    public func expansion(for abbreviation: String) -> String? {
        entries[abbreviation.lowercased()]
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 第一次開啟時寫進檔案的範例
    public static let template = """
    # 融鍵快捷文字本
    # 每行一組：縮寫 空白 展開內容。縮寫只能用英文字母與數字。
    # 打縮寫後按空白，展開內容會排在候選第一位；再按空白或 Enter 送出。
    # 存檔後立刻生效，不用重新啟動。
    #
    # addr 台北市信義區市府路1號
    # tel 02-1234-5678
    # thx 謝謝您，再麻煩了！
    """
}
