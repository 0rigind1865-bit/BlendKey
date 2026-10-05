/// 音節組字器：吃大千鍵位、維護組字中的音節，調號落下即完成一個音節。
public struct SyllableComposer: Equatable, Sendable {

    public enum PressResult: Equatable, Sendable {
        case absorbed            // 併入組字中的音節
        case composed(Syllable)  // 調號落下，音節完成（組字器已清空）
        case rejected            // 不是注音鍵，或調號打在空音節上
    }

    private enum Slot: Equatable { case initial, medial, final }

    public private(set) var syllable = Syllable()
    /// 已按下的原始按鍵（供英文自動偵測；含被覆寫的鍵）
    public private(set) var rawKeys = ""
    /// 同槽被覆寫的次數：注音打字幾乎不覆寫，連續覆寫多半是在打英文
    public private(set) var overwriteCount = 0
    private var slotOrder: [Slot] = []

    public init() {}

    public var isEmpty: Bool { syllable.isEmpty }
    public var display: String { syllable.display }

    public mutating func press(_ key: Character) -> PressResult {
        guard let component = DachenLayout.component(for: key) else { return .rejected }
        switch component {
        case .tone(let tone):
            guard !syllable.isEmpty else { return .rejected }
            syllable.tone = tone
            var done = syllable
            // 只有介母／韻母缺失時仍算合法音節（如 ㄦ、ㄇ˙ 不成立由詞庫過濾）
            done.tone = tone
            clear()
            return .composed(done)
        case .initial(let value):
            syllable.initial = value
            noteSlot(.initial, key: key)
        case .medial(let value):
            syllable.medial = value
            noteSlot(.medial, key: key)
        case .final(let value):
            syllable.final = value
            noteSlot(.final, key: key)
        }
        return .absorbed
    }

    /// 退掉最後一個按鍵：用剩下的原始按鍵重播一次。
    /// 打英文時字母會覆寫注音槽（google 只佔 2 槽），退槽的話退兩下整串就消失；
    /// 重播＝真正的「上一個按鍵沒按過」，覆寫前的注音也會還原。組字器已空回傳 false
    public mutating func backspace() -> Bool {
        guard !rawKeys.isEmpty else {
            clear()
            return false
        }
        let keys = rawKeys.dropLast()
        clear()
        for key in keys { _ = press(key) }
        return true
    }

    public mutating func clear() {
        syllable = Syllable()
        slotOrder = []
        rawKeys = ""
        overwriteCount = 0
    }

    private mutating func noteSlot(_ slot: Slot, key: Character) {
        // 覆寫同槽時保持原順位，避免 backspace 順序錯亂
        if slotOrder.contains(slot) {
            overwriteCount += 1
        } else {
            slotOrder.append(slot)
        }
        rawKeys.append(key)
    }
}
