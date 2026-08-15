/// 注音音節：聲母／介母／韻母／聲調 四槽。
/// canonical 字串與詞庫讀音一致：組件依序相接，一聲不標、輕聲「˙」綴於尾（如 ㄅㄚ˙）。
public struct Syllable: Equatable, Sendable {

    public enum Initial: String, Sendable, CaseIterable {
        case b = "ㄅ", p = "ㄆ", m = "ㄇ", f = "ㄈ"
        case d = "ㄉ", t = "ㄊ", n = "ㄋ", l = "ㄌ"
        case g = "ㄍ", k = "ㄎ", h = "ㄏ"
        case j = "ㄐ", q = "ㄑ", x = "ㄒ"
        case zh = "ㄓ", ch = "ㄔ", sh = "ㄕ", r = "ㄖ"
        case z = "ㄗ", c = "ㄘ", s = "ㄙ"
    }

    public enum Medial: String, Sendable, CaseIterable {
        case i = "ㄧ", u = "ㄨ", yu = "ㄩ"
    }

    public enum Final: String, Sendable, CaseIterable {
        case a = "ㄚ", o = "ㄛ", e = "ㄜ", eh = "ㄝ"
        case ai = "ㄞ", ei = "ㄟ", ao = "ㄠ", ou = "ㄡ"
        case an = "ㄢ", en = "ㄣ", ang = "ㄤ", eng = "ㄥ"
        case er = "ㄦ"
    }

    public enum Tone: Int, Sendable, CaseIterable {
        case tone1 = 1, tone2, tone3, tone4, tone5

        /// 詞庫讀音使用的調號（一聲不標）
        public var mark: String {
            switch self {
            case .tone1: return ""
            case .tone2: return "ˊ"
            case .tone3: return "ˇ"
            case .tone4: return "ˋ"
            case .tone5: return "˙"
            }
        }
    }

    public var initial: Initial?
    public var medial: Medial?
    public var final: Final?
    public var tone: Tone?

    public init() {}

    public var isEmpty: Bool {
        initial == nil && medial == nil && final == nil && tone == nil
    }

    /// 組字中顯示（不含調號）
    public var display: String {
        (initial?.rawValue ?? "") + (medial?.rawValue ?? "") + (final?.rawValue ?? "")
    }

    /// 與詞庫一致的完整讀音
    public var canonical: String {
        display + (tone?.mark ?? "")
    }
}

/// 一個按鍵對應到的注音組件
public enum ZhuyinComponent: Equatable, Sendable {
    case initial(Syllable.Initial)
    case medial(Syllable.Medial)
    case final(Syllable.Final)
    case tone(Syllable.Tone)

    public var isTone: Bool {
        if case .tone = self { return true }
        return false
    }
}
