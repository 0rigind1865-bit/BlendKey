/// 平台無關的按鍵抽象：IMK 殼層與 CLI 都先轉成這個型別再餵引擎，
/// 讓核心邏輯的測試完全不需要 NSEvent。
public enum KeyInput: Equatable, Sendable {
    /// 未修飾的可列印字元（字母、數字、符號）
    case character(Character)
    /// 同一鍵的自動重複事件（長按）：引擎據此判斷使用者要原始字元
    case repeatedCharacter(Character)
    /// Shift+字母直出英文：字元已含大小寫資訊
    case englishLiteral(Character)
    case space
    case enter
    case escape
    case backspace
    case tab
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case pageUp
    case pageDown
}
