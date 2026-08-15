import Carbon
import Cocoa
import InputMethodKit
import BlendKeyCore

/// IMK 殼層：把 NSEvent 轉成 KeyInput 餵核心引擎，再把結果寫回 client。
/// 類別名以 @objc 固定，對應 Info.plist 的 InputMethodServerControllerClass。
@objc(BlendKeyInputController)
class BlendKeyInputController: IMKInputController {

    // M0：先用簡單字串緩衝驗證 marked text 管線，M1 換成 InputEngine
    private var buffer = ""

    private let kNoRange = NSRange(location: NSNotFound, length: NSNotFound)

    override func recognizedEvents(_ sender: Any!) -> Int {
        // flagsChanged 供 M3 的 Shift 單擊偵測；現在先收下但忽略
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        guard event.type == .keyDown else { return false }

        switch event.keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            guard !buffer.isEmpty else { return false }
            commit(to: client)
            return true
        case UInt16(kVK_Escape):
            guard !buffer.isEmpty else { return false }
            buffer = ""
            updateMarkedText(client)
            return true
        case UInt16(kVK_Delete):
            guard !buffer.isEmpty else { return false }
            buffer.removeLast()
            updateMarkedText(client)
            return true
        default:
            break
        }

        guard let chars = event.characters, chars.count == 1,
              let ch = chars.first, ch.isLetter, ch.isASCII,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option)
        else {
            return false
        }
        buffer.append(ch)
        updateMarkedText(client)
        return true
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput, !buffer.isEmpty else { return }
        commit(to: client)
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
    }

    private func commit(to client: IMKTextInput) {
        client.insertText(buffer, replacementRange: kNoRange)
        buffer = ""
        updateMarkedText(client)
    }

    private func updateMarkedText(_ client: IMKTextInput) {
        let range = NSRange(location: 0, length: buffer.utf16.count)
        let attrs = mark(forStyle: Int(kTSMHiliteSelectedRawText), at: range) as? [NSAttributedString.Key: Any]
            ?? [.underlineStyle: NSUnderlineStyle.single.rawValue]
        client.setMarkedText(
            NSAttributedString(string: buffer, attributes: attrs),
            selectionRange: NSRange(location: buffer.utf16.count, length: 0),
            replacementRange: kNoRange
        )
    }
}
