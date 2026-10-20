import Foundation

/// 符號表：組字器空著時按 ` 叫出。一頁一類（預設每頁 9 個）。
/// ponytail: 平面清單分頁當分類；每頁字數改成 9 以外時分類會錯位，要真正兩層選單再改
public enum SymbolTable {
    public static let symbols: [String] = [
        // 標點
        "…", "——", "《", "》", "〈", "〉", "～", "・", "※",
        // 括號引號
        "【", "】", "〔", "〕", "『", "』", "“", "”", "｜",
        // 箭頭
        "→", "←", "↑", "↓", "↔", "⇒", "⇐", "↗", "↘",
        // 數學
        "±", "×", "÷", "≠", "≒", "≦", "≧", "∞", "√",
        // 單位
        "℃", "°", "％", "‰", "㎜", "㎝", "㎏", "㎡", "Ω",
        // 圈號數字
        "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨",
        // 圖形
        "★", "☆", "●", "○", "■", "□", "◆", "◇", "▲",
        // 勾叉與雜項
        "✓", "✗", "♪", "♫", "☎", "✉", "♥", "⚠", "☺",
        // 貨幣（₫ 越南盾）
        "NT$", "＄", "¥", "€", "£", "₩", "₫", "฿", "¢",
        // 框線
        "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┼",
    ]
}

/// 數字的各種寫法：1234 → 1,234、壹仟貳佰參拾肆、新臺幣…元整、一千二百三十四…
public enum NumberForms {
    /// 第一個永遠是原樣；不是數字（或超過 16 位整數）就回空陣列
    public static func forms(of text: String) -> [String] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let integer = parts.first, !integer.isEmpty, integer.count <= 16,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return [] }
        let fraction = parts.count == 2 ? String(parts[1]) : nil

        func spelled(_ digits: [String], units: [String], dropLeadingOne: Bool) -> String {
            var out = chinese(String(integer), digits: digits, units: units)
            if dropLeadingOne, out.hasPrefix(digits[1] + units[1]) { out.removeFirst() }  // 一十五 → 十五
            if let fraction { out += "點" + fraction.map { digits[$0.wholeNumberValue!] }.joined() }
            return out
        }
        let upper = spelled(upperDigits, units: upperUnits, dropLeadingOne: false)
        var result = [
            text,
            grouped(String(integer)) + (fraction.map { "." + $0 } ?? ""),
            upper,
        ]
        if fraction == nil { result.append("新臺幣" + upper + "元整") }
        result += [
            spelled(lowerDigits, units: lowerUnits, dropLeadingOne: true),
            text.map { $0 == "." ? "點" : lowerDigits[$0.wholeNumberValue!] }.joined(),
            String(text.unicodeScalars.map { Character(Unicode.Scalar($0.value + 0xFEE0)!) }),  // 全形
        ]
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static let upperDigits = ["零", "壹", "貳", "參", "肆", "伍", "陸", "柒", "捌", "玖"]
    private static let upperUnits = ["", "拾", "佰", "仟"]
    private static let lowerDigits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let lowerUnits = ["", "十", "百", "千"]
    private static let bigUnits = ["", "萬", "億", "兆"]

    /// 四位一節：節尾的零不讀、節內與整節的零只讀一個「零」
    private static func chinese(_ integer: String, digits: [String], units: [String]) -> String {
        let values = integer.drop { $0 == "0" }.map { $0.wholeNumberValue! }
        guard !values.isEmpty else { return "零" }
        let padded = Array(repeating: 0, count: (4 - values.count % 4) % 4) + values
        let groups = stride(from: 0, to: padded.count, by: 4).map { Array(padded[$0..<$0 + 4]) }
        var out = ""
        var pendingZero = false
        for (index, group) in groups.enumerated() {
            guard let last = group.lastIndex(where: { $0 != 0 }) else {
                pendingZero = !out.isEmpty  // 整節是零
                continue
            }
            for (position, digit) in group.enumerated() where position <= last {
                if digit == 0 {
                    if !out.isEmpty { pendingZero = true }
                    continue
                }
                if pendingZero { out += "零"; pendingZero = false }
                out += digits[digit] + units[3 - position]
            }
            out += bigUnits[groups.count - 1 - index]
        }
        return out
    }

    private static func grouped(_ integer: String) -> String {
        var out = ""
        for (offset, ch) in integer.enumerated() {
            if offset > 0, (integer.count - offset) % 3 == 0 { out += "," }
            out.append(ch)
        }
        return out
    }
}

/// 日期時間快打：打「今天」「現在」等詞，候選窗裡多出日期時間的各種寫法
public enum DateMacro {
    /// 讀音 → 相對今天的天數（nil＝時間）
    private static let readings: [String: Int?] = [
        "ㄐㄧㄣ-ㄊㄧㄢ": 0, "ㄇㄧㄥˊ-ㄊㄧㄢ": 1, "ㄏㄡˋ-ㄊㄧㄢ": 2,
        "ㄗㄨㄛˊ-ㄊㄧㄢ": -1, "ㄑㄧㄢˊ-ㄊㄧㄢ": -2,
        "ㄒㄧㄢˋ-ㄗㄞˋ": nil,
    ]
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    public static func forms(for reading: String, now: Date = Date()) -> [String] {
        guard let offset = readings[reading] else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(byAdding: .day, value: offset ?? 0, to: now)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: day)
        let (y, m, d) = (c.year!, c.month!, c.day!)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let iso = "\(y)-\(two(m))-\(two(d))"
        guard offset != nil else {
            let (h, minute) = (c.hour!, c.minute!)
            let half = h < 12 ? "上午" : "下午"
            let h12 = h % 12 == 0 ? 12 : h % 12
            return ["\(two(h)):\(two(minute))", "\(half)\(h12):\(two(minute))", "\(iso) \(two(h)):\(two(minute))"]
        }
        return [
            iso,
            "\(y)/\(two(m))/\(two(d))",
            "\(y)年\(m)月\(d)日",
            "民國\(y - 1911)年\(m)月\(d)日",
            "\(m)月\(d)日（\(weekdays[c.weekday! - 1])）",
        ]
    }
}

/// AI 補句的輸出過濾（殼層問完 AI 後用）：清掉模型常見的毛病
public enum CompletionFilter {
    /// 清掉模型常見的毛病；看起來不像「接著打的字」就整個丟掉（回傳 nil）
    public static func clean(_ output: String, text: String, before: String) -> String? {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for given in [before + text, text] where !given.isEmpty && result.hasPrefix(given) {
            result.removeFirst(given.count)  // 把原文重打一遍
            break
        }
        // 只留到第一個句尾或換行：灰字補一小段就好
        if let end = result.firstIndex(where: { "。！？\n".contains($0) }) {
            result = String(result[..<end])
        }
        result = String(result.prefix(12)).trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return nil }
        // ponytail: 擋「像客服在回話」與鬼打牆的粗略規則，實際用下來再調
        let chatty = ["我會", "幫你", "幫您", "您", "請告訴", "好的", "抱歉", "打字"]
        if chatty.contains(where: result.contains) { return nil }
        let chars = Array(result)
        if chars.count >= 4, Set(chars).count * 2 <= chars.count { return nil }  // 寫字寫字寫字
        return result
    }
}
