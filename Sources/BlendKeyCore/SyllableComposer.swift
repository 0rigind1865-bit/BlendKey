/// 音節組字器：吃大千鍵位、維護組字中的音節，調號落下即完成一個音節。
public struct SyllableComposer: Equatable, Sendable {

    public enum PressResult: Equatable, Sendable {
        case absorbed            // 併入組字中的音節
        case composed(Syllable)  // 調號落下，音節完成（組字器已清空）
        case rejected            // 不是注音鍵，或調號打在空音節上
    }

    private enum Slot: Equatable { case initial, medial, final }

    public private(set) var syllable = Syllable()
    /// 已按下的原始按鍵（供 M3 英文自動偵測；含被覆寫的鍵）
    public private(set) var rawKeys = ""
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

    /// 清掉最後一個填入的槽；組字器已空回傳 false
    public mutating func backspace() -> Bool {
        guard let last = slotOrder.popLast() else {
            clear()
            return false
        }
        switch last {
        case .initial: syllable.initial = nil
        case .medial: syllable.medial = nil
        case .final: syllable.final = nil
        }
        if !rawKeys.isEmpty { rawKeys.removeLast() }
        return true
    }

    public mutating func clear() {
        syllable = Syllable()
        slotOrder = []
        rawKeys = ""
    }

    private mutating func noteSlot(_ slot: Slot, key: Character) {
        // 覆寫同槽時保持原順位，避免 backspace 順序錯亂
        if !slotOrder.contains(slot) { slotOrder.append(slot) }
        rawKeys.append(key)
    }
}
