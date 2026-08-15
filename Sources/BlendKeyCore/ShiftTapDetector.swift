/// Shift 單擊偵測狀態機（純邏輯，IMK 殼層把 flagsChanged 轉成 FlagsEvent 餵進來）。
/// 規則（參考業界慣例，clean-room 實作）：
/// 1. 只認左右 Shift 的按下（且當下除 Caps Lock 外無其他修飾鍵）
/// 2. 按下到放開之間出現任何一般按鍵 → 取消（與 Shift+字母直出英文自然相容）
/// 3. 按住超過 0.3 秒視為長按，不觸發
/// 4. 連續觸發間隔 0.05 秒內忽略（Electron 應用會送冗餘 flagsChanged）
public struct ShiftTapDetector: Sendable {

    public enum FlagsEvent: Equatable, Sendable {
        case shiftDown(keyCode: UInt16)   // Shift 按下，且除 Caps Lock 外只有 shift 旗標
        case allReleased(keyCode: UInt16) // 修飾鍵全放開（除 Caps Lock）
        case other                        // 其他修飾鍵變化
    }

    private var pending: (keyCode: UInt16, downAt: Double)?
    private var lastFiredAt = -1.0

    public init() {}

    /// 回傳 true 表示完成一次 Shift 單擊（該切換中英了）
    public mutating func process(_ event: FlagsEvent, at time: Double) -> Bool {
        switch event {
        case .shiftDown(let keyCode):
            pending = (keyCode, time)
            return false
        case .allReleased(let keyCode):
            guard let armed = pending, armed.keyCode == keyCode else {
                pending = nil
                return false
            }
            pending = nil
            guard time - armed.downAt < 0.3 else { return false }      // 長按
            guard time - lastFiredAt > 0.05 else { return false }      // 防抖
            lastFiredAt = time
            return true
        case .other:
            pending = nil
            return false
        }
    }

    /// 一般按鍵落下：取消進行中的 Shift 單擊
    public mutating func noteKeyDown() {
        pending = nil
    }
}
