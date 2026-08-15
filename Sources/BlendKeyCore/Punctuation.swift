/// 全形標點映射：中文模式下，非注音鍵位的標點直接轉全形。
/// 逗號句號等鍵的未 Shift 版本是注音（,=ㄝ .=ㄡ /=ㄥ），
/// 所以這裡收的是 Shift 後的字元（< > ?）與本來就空著的鍵（' [ ]）。
public enum Punctuation {
    private static let map: [Character: String] = [
        "<": "，", ">": "。", "?": "？", "!": "！", ":": "：",
        "'": "、", "\"": "；",
        "[": "「", "]": "」", "{": "『", "}": "』",
        "(": "（", ")": "）",
    ]

    public static func fullWidth(_ ch: Character) -> String? {
        map[ch]
    }
}
