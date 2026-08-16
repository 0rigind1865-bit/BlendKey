/// 反向偵測：英文模式下觀察按鍵流（不攔截），判斷使用者其實在打注音。
///
/// 觸發條件（保守設計，避免英文誤判）：
/// 連續 ≥2 個「零覆寫、詞庫查得到」的完整音節，且串中至少一個是數字聲調（ˊˇˋ˙）。
/// 英文透過大千鍵位幾乎必產生覆寫（hello → 3 次），且字母串中不會夾數字，
/// 兩個條件都過的只會是真的注音。
public struct ChineseTypingDetector: Sendable {

    private var shadow = SyllableComposer()
    private var validStreak = 0
    private var sawDigitTone = false
    private var pendingKeys = ""  // 進行中音節的按鍵
    private var streakKeys = ""   // 已完成合法音節的按鍵串
    private let isKnownReading: @Sendable (String) -> Bool

    public init(isKnownReading: @escaping @Sendable (String) -> Bool) {
        self.isKnownReading = isKnownReading
    }

    /// 餵一個可列印按鍵。回傳非 nil＝該切回中文了，值是整串注音按鍵
    /// （如 "su3cl3"，供殼層把已放行的字母收回重組）；同時自我重置。
    public mutating func feed(_ ch: Character) -> String? {
        let overwritesBefore = shadow.overwriteCount
        switch shadow.press(ch) {
        case .absorbed:
            pendingKeys.append(ch)
            return nil
        case .composed(let syllable):
            pendingKeys.append(ch)
            guard overwritesBefore == 0, isKnownReading(syllable.canonical) else {
                resetStreak()
                return nil
            }
            streakKeys += pendingKeys
            pendingKeys = ""
            validStreak += 1
            if syllable.tone != .tone1 { sawDigitTone = true }
            if validStreak >= 2 && sawDigitTone {
                let keys = streakKeys
                reset()
                return keys
            }
            return nil
        case .rejected:
            // 非注音鍵（標點、其他符號）：打斷節奏
            resetStreak()
            return nil
        }
    }

    /// 任何非打字事件（方向鍵、退格、切換視窗…）都該打斷偵測
    public mutating func reset() {
        shadow.clear()
        resetStreak()
    }

    private mutating func resetStreak() {
        shadow.clear()
        validStreak = 0
        sawDigitTone = false
        pendingKeys = ""
        streakKeys = ""
    }
}
