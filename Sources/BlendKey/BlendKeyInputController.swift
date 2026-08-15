import Carbon
import Cocoa
import InputMethodKit
import BlendKeyCore

/// IMK 殼層：把 NSEvent 轉成 KeyInput 餵核心引擎，把結果寫回 client。
/// 類別名以 @objc 固定，對應 Info.plist 的 InputMethodServerControllerClass。
@objc(BlendKeyInputController)
class BlendKeyInputController: IMKInputController {

    private var engine: InputEngine?
    private let kNoRange = NSRange(location: NSNotFound, length: NSNotFound)

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
        LexiconStore.bootstrap()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // flagsChanged 供 M3 的 Shift 單擊偵測
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        // 硬體鍵盤若非 US 配置（如 Dvorak），強制以 ABC 鍵位對應大千
        client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        CandidatePanel.shared.dismiss(owner: self)
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput, let engine else { return }
        if let text = engine.flush() {
            client.insertText(text, replacementRange: kNoRange)
        }
        syncUI(engine, client: client)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        guard event.type == .keyDown else { return false }  // flagsChanged：M3
        guard let engine = ensureEngine() else { return false }  // 詞庫載入前放行

        // cmd／ctrl／opt 快捷鍵：先把組字區上屏，再放行給應用程式
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            flushBeforePassthrough(engine, client: client)
            return false
        }
        guard let key = keyInput(from: event) else {
            flushBeforePassthrough(engine, client: client)
            return false
        }

        let output = engine.handle(key)
        if let commit = output.commitText {
            client.insertText(commit, replacementRange: kNoRange)
        }
        syncUI(engine, client: client)
        return output.handled
    }

    // MARK: - 按鍵轉換

    private func keyInput(from event: NSEvent) -> KeyInput? {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Escape: return .escape
        case kVK_Delete: return .backspace
        case kVK_Tab: return .tab
        case kVK_LeftArrow: return .arrowLeft
        case kVK_RightArrow: return .arrowRight
        case kVK_UpArrow: return .arrowUp
        case kVK_DownArrow: return .arrowDown
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Space: return .space
        default: break
        }
        guard let chars = event.characters, chars.count == 1, let ch = chars.first else { return nil }
        if ch == " " { return .space }
        if event.modifierFlags.contains(.shift), ch.isLetter {
            return nil  // M1：Shift+字母放行；M3 改為 .englishLiteral 直出
        }
        guard ch.isASCII, !ch.isNewline else { return nil }
        // 統一小寫餵大千鍵位表；數字與符號原樣（引擎自行判斷選字／拒收）
        return .character(Character(String(ch).lowercased()))
    }

    // MARK: - UI 同步

    private func ensureEngine() -> InputEngine? {
        if engine == nil, let lexicon = LexiconStore.lexicon {
            engine = InputEngine(lexicon: lexicon)
        }
        return engine
    }

    private func flushBeforePassthrough(_ engine: InputEngine, client: IMKTextInput) {
        guard !engine.isIdle else { return }
        if let text = engine.flush() {
            client.insertText(text, replacementRange: kNoRange)
        }
        syncUI(engine, client: client)
    }

    private func syncUI(_ engine: InputEngine, client: IMKTextInput) {
        setMarked(engine.preedit(), client: client)
        if let sheet = engine.sheetView() {
            var lineRect = NSRect.zero
            client.attributes(forCharacterIndex: sheet.anchorUTF16, lineHeightRectangle: &lineRect)
            CandidatePanel.shared.present(
                sheet, near: lineRect, clientLevel: client.windowLevel(), owner: self
            )
        } else {
            CandidatePanel.shared.dismiss(owner: self)
        }
    }

    private func setMarked(_ preedit: InputEngine.Preedit, client: IMKTextInput) {
        let attributed = NSMutableAttributedString()
        var location = 0
        for piece in preedit.pieces {
            let style: Int
            switch piece.style {
            case .converted: style = Int(kTSMHiliteConvertedText)
            case .active: style = Int(kTSMHiliteSelectedConvertedText)
            case .raw: style = Int(kTSMHiliteSelectedRawText)
            }
            let range = NSRange(location: location, length: piece.text.utf16.count)
            let attrs = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any]
                ?? [.underlineStyle: NSUnderlineStyle.single.rawValue]
            attributed.append(NSAttributedString(string: piece.text, attributes: attrs))
            location += piece.text.utf16.count
        }
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: preedit.caretUTF16, length: 0),
            replacementRange: kNoRange
        )
    }
}
