import Carbon
import Cocoa
import InputMethodKit
import BlendKeyCore

/// IMK 殼層：把 NSEvent 轉成 KeyInput 餵核心引擎，把結果寫回 client。
/// 類別名以 @objc 固定，對應 Info.plist 的 InputMethodServerControllerClass。
@objc(BlendKeyInputController)
class BlendKeyInputController: IMKInputController {

    /// 中／英模式是整個輸入法共享的（跨應用程式一致）
    private static var chineseMode = true
    private static var shiftDetector = ShiftTapDetector()
    /// 右 Option 單擊＝語音輸入。偵測器只看 keyCode，借用 Shift 單擊同一台狀態機
    private static var optionDetector = ShiftTapDetector()
    /// 反向偵測：英文模式下發現在打注音就自動切回中文
    private static var chineseDetector = ChineseTypingDetector { reading in
        LexiconStore.lexicon?.unigrams(reading).isEmpty == false
    }
    /// 大寫燈亮著卻在打注音：當它沒亮，直到使用者自己切換大寫才恢復
    private static var capsLockOverridden = false
    /// 這段放行字母在文件裡的起點（用位置算術驗證，不需 app 支援讀取內容）
    private static var passthroughAnchor: Int?
    /// 使用者選字學習：全行程共用一份（main.swift 結束前要 flush）
    static let userPhrases = UserPhraseStore(
        fileURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlendKey/userphrases.json")
    )

    private var engine: InputEngine?
    /// 上次問 AI 的組字內容：同樣內容不重問（被過濾掉時也不會一直重試）
    private static var lastCompletionRequest: String?
    /// 上次送去校正的組字內容：同樣內容不重問
    private static var lastCorrectionRequest: String?
    /// AI 補句至少要看到幾個字（組字中＋游標前同一行）：字太少 AI 多半亂猜，跳出來只是干擾。
    /// ponytail: 固定 6 字，嫌早或嫌晚再調、或改成偏好設定
    private static let minimumCompletionContext = 6
    private let kNoRange = NSRange(location: NSNotFound, length: NSNotFound)

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
        LexiconStore.bootstrap()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // flagsChanged 供 Shift 單擊偵測
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let mode = NSMenuItem(
            title: "目前模式：\(Self.chineseMode ? "中文" : "英文")（Shift 切換）",
            action: nil, keyEquivalent: ""
        )
        mode.isEnabled = false
        menu.addItem(mode)
        menu.addItem(.separator())
        for (title, action) in [
            ("操作說明…", #selector(showGuide(_:))),
            ("學習資料…", #selector(showLearnedData(_:))),
            ("偏好設定…", #selector(showPreferences(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showGuide(_ sender: Any?) {
        GuideWindowController.shared.show()
    }

    @objc private func showLearnedData(_ sender: Any?) {
        LearnedDataWindowController.shared.show(store: Self.userPhrases)
    }

    /// IMK 內建的偏好設定進入點，換成自己的 SwiftUI 視窗
    override func showPreferences(_ sender: Any!) {
        SettingsWindowController.shared.onReset = { Self.userPhrases.reset() }
        SettingsWindowController.shared.onShowLearnedData = {
            LearnedDataWindowController.shared.show(store: Self.userPhrases)
        }
        SettingsWindowController.shared.show()
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
        guard let client = sender as? IMKTextInput else { return }
        if VoiceInput.shared.isListening {
            endVoice(VoiceInput.shared.finishNow(), client: client)
        }
        guard let engine else { return }
        if let text = engine.flush() {
            client.insertText(text, replacementRange: kNoRange)
        }
        syncUI(engine, client: client)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }

        if event.type == .flagsChanged {
            handleFlagsChanged(event, client: client)
            return false  // 修飾鍵事件永遠放行
        }
        guard event.type == .keyDown else { return false }
        Self.shiftDetector.noteKeyDown()
        Self.optionDetector.noteKeyDown()

        // 語音輸入中按任何鍵：先把聽到的字上屏。Esc＝不要了；Enter＝只上屏；其他鍵照常處理
        if VoiceInput.shared.isListening {
            let heard = VoiceInput.shared.finishNow()
            switch Int(event.keyCode) {
            case kVK_Escape:
                endVoice("", client: client)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                endVoice(heard, client: client)
                return true
            default:
                endVoice(heard, client: client)
            }
        }

        guard Self.chineseMode else {
            // 英文模式：放行但觀察——發現在打注音就切回中文並收回已打出的字母
            return englishPassthrough(event, client: client)
        }
        guard let engine = ensureEngine() else { return false }  // 詞庫載入前放行

        // Caps Lock 亮：英數直通。但仍觀察按鍵流——大寫燈很容易誤觸，
        // 發現在打注音就當它沒亮（收回字母重組），直到使用者自己切換大寫。
        if event.modifierFlags.contains(.capsLock), !Self.capsLockOverridden {
            flushBeforePassthrough(engine, client: client)
            return englishPassthrough(event, client: client)
        }

        // cmd／ctrl／opt 快捷鍵：先把組字區上屏，再放行給應用程式
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            flushBeforePassthrough(engine, client: client)
            return false
        }
        guard let key = keyInput(from: event) else {
            flushBeforePassthrough(engine, client: client)
            return false
        }

        let wasInLiteralRun = engine.isInLiteralRun
        let output = engine.handle(key)
        if let commit = output.commitText {
            client.insertText(commit, replacementRange: kNoRange)
        }
        syncUI(engine, client: client)
        // 英文段裡打注音被自動切回：閃「中」，跟 Shift 單擊一樣有回饋
        if wasInLiteralRun, !engine.isInLiteralRun {
            switch key {
            case .character, .space: ModeHUD.shared.flash(chinese: true, near: caretLineRect(client))
            default: break  // Esc／方向鍵結束英文段不閃
            }
        }
        return output.handled
    }

    /// 英文放行：照原廠，中/英鍵（Caps Lock）亮燈只是切英文，字母仍是小寫；要大寫按住 Shift。
    private func englishPassthrough(_ event: NSEvent, client: IMKTextInput) -> Bool {
        if observeEnglishModeTyping(event, client: client) { return true }
        guard event.modifierFlags.contains(.capsLock),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.characters, chars.count == 1, let ch = chars.first,
              ch.isASCII, ch.isLetter
        else { return false }
        let out = event.modifierFlags.contains(.shift) ? chars.uppercased() : chars.lowercased()
        client.insertText(out, replacementRange: kNoRange)
        return true
    }

    /// 英文模式的旁路觀察：放行並偵測。觸發時把已放行的注音字母收回、原地重組成中文。
    /// 回傳 true 表示這個按鍵被吃掉（觸發鍵不再進文件）。
    private func observeEnglishModeTyping(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingKey.englishHint),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.characters, chars.count == 1, let ch = chars.first,
              ch.isASCII, !ch.isNewline, ch == " " || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol
        else {
            Self.chineseDetector.reset()  // 快捷鍵、方向鍵等：打斷偵測節奏
            Self.passthroughAnchor = nil
            return false
        }
        // 新一段的起點：記下這個字母插入前的游標位置
        if !Self.chineseDetector.isTracking {
            let location = client.selectedRange().location
            Self.passthroughAnchor = location == NSNotFound ? nil : location
        }
        guard let keys = Self.chineseDetector.feed(Character(String(ch).lowercased())) else {
            return false
        }

        // 觸發後一律回中文組字；大寫燈亮就再疊加「當它沒亮」。
        // 兩者是獨立狀態——英文模式＋大寫燈同時成立時，只解其中一個
        // 會讓下一鍵仍被放行，把剛組出的中文蓋掉（使用者實測踩到的疊加 bug）。
        if event.modifierFlags.contains(.capsLock) {
            Self.capsLockOverridden = true
        }
        Self.chineseMode = true
        ModeHUD.shared.flash(chinese: true, near: caretLineRect(client))

        // 觸發鍵還沒進文件；文件裡是前面已放行的字母（keys 去掉最後一鍵）
        let emitted = String(keys.dropLast())
        let length = emitted.utf16.count
        let selection = client.selectedRange()

        // 先驗證游標合法，才能安全計算範圍（NSNotFound 相減會溢位，
        // 拿溢位範圍去 attributedSubstring 在嚴格的 app 會丟例外）
        guard let engine = ensureEngine(),
              selection.location != NSNotFound, selection.length == 0,
              selection.location >= length
        else {
            Log.general.error("反向偵測：切回中文但游標狀態不明（\(selection.location)），不收回")
            Self.passthroughAnchor = nil
            return false  // 觸發鍵放行，維持原字母
        }

        // 驗證這段字母確實還完整躺在游標前面（使用者可能中途移動過游標）。
        // 內容比對優先（大小寫不計，大寫模式放行的是大寫）；app 不給讀才信位置算術。
        let documentRange = NSRange(location: selection.location - length, length: length)
        let anchorMatches = Self.passthroughAnchor.map { $0 + length == selection.location } ?? false
        let content = client.attributedSubstring(from: documentRange)?.string
        let contentMatches = content.map { $0.lowercased() == emitted.lowercased() }

        guard contentMatches ?? anchorMatches else {
            let anchorText = Self.passthroughAnchor.map(String.init) ?? "無"
            let detail = "游標 \(selection.location)、需 \(length) 字、起點 \(anchorText)、內容 \(content ?? "讀不到")"
            Log.general.error("反向偵測：切回中文但無法收回字母（\(detail, privacy: .public)）")
            Self.passthroughAnchor = nil
            return false
        }

        Log.general.info("反向偵測：切回中文並收回 \(emitted.count + 1, privacy: .public) 個字母重組")
        Self.passthroughAnchor = nil
        for key in keys {
            _ = engine.handle(key == " " ? .space : .character(key))
        }
        setMarked(engine.preedit(), client: client, replacing: documentRange)
        return true  // 觸發鍵由我們消化，不讓它再進文件
    }

    /// Shift 單擊切換中英。flagsChanged 在 NSMenu／開存檔對話框中收不到（平台限制）。
    private func handleFlagsChanged(_ event: NSEvent, client: IMKTextInput) {
        // Caps Lock 切換：亮＝英數直通模式（比照內建注音的習慣）
        if event.keyCode == UInt16(kVK_CapsLock) {
            let capsOn = event.modifierFlags.contains(.capsLock)
            Self.capsLockOverridden = false  // 使用者自己切換，恢復尊重大寫燈
            Self.chineseDetector.reset()
            if capsOn, let engine, let text = engine.flush() {
                client.insertText(text, replacementRange: kNoRange)
            }
            if let engine { syncUI(engine, client: client) }
            ModeHUD.shared.flash(chinese: !capsOn && Self.chineseMode, near: caretLineRect(client))
            return
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if UserDefaults.standard.bool(forKey: SettingKey.voiceInput) {
            let isRightOption = event.keyCode == UInt16(kVK_RightOption)
            let optionEvent: ShiftTapDetector.FlagsEvent =
                isRightOption && flags == .option ? .shiftDown(keyCode: event.keyCode)
                : isRightOption && flags.isEmpty ? .allReleased(keyCode: event.keyCode)
                : .other
            if Self.optionDetector.process(optionEvent, at: event.timestamp) {
                toggleVoice(client)
                return
            }
        }
        guard UserDefaults.standard.bool(forKey: SettingKey.shiftToggle) else { return }
        let isShiftKey = event.keyCode == 56 || event.keyCode == 60  // 左／右 Shift

        let flagsEvent: ShiftTapDetector.FlagsEvent
        if isShiftKey && flags == .shift {
            flagsEvent = .shiftDown(keyCode: event.keyCode)
        } else if isShiftKey && flags.isEmpty {
            flagsEvent = .allReleased(keyCode: event.keyCode)
        } else {
            flagsEvent = .other
        }
        guard Self.shiftDetector.process(flagsEvent, at: event.timestamp) else { return }

        // 英文接續段進行中：Shift 單擊＝結束該段回中文組字，不切整體模式
        if let engine, engine.isInLiteralRun {
            engine.endLiteralRun()
            ModeHUD.shared.flash(chinese: true, near: caretLineRect(client))
            return
        }

        Self.chineseMode.toggle()
        Log.general.info("切換模式：\(Self.chineseMode ? "中文" : "英文", privacy: .public)")
        if !Self.chineseMode, let engine {
            // 切到英文前先把組字區上屏
            if let text = engine.flush() {
                client.insertText(text, replacementRange: kNoRange)
            }
            syncUI(engine, client: client)
        }
        ModeHUD.shared.flash(chinese: Self.chineseMode, near: caretLineRect(client))
    }

    // MARK: - 語音輸入

    /// 右 Option 單擊：沒在聽就開始（打一半的字先上屏，講的接在後面）；在聽就結束
    private func toggleVoice(_ client: IMKTextInput) {
        let voice = VoiceInput.shared
        if voice.isListening {
            voice.stop()  // 等辨識器送回定案結果，由 onFinal 上屏
            return
        }
        if let engine { flushBeforePassthrough(engine, client: client) }
        // 智慧輸入總開關有開：講話的同時先把模型伺服器叫起來，講完才來得及整理
        if UserDefaults.standard.bool(forKey: SettingKey.smartInput) { SmartInput.setEnabled(true) }
        showVoice("", client: client)
        voice.start(
            onPartial: { [weak self] text in self?.showVoice(text, client: client) },
            onFinal: { [weak self] text in self?.endVoice(text, client: client) }
        )
    }

    /// 辨識中：游標旁顯示聲波，聽到的字以組字區（底線）即時顯示
    private func showVoice(_ text: String, client: IMKTextInput) {
        client.setMarkedText(
            NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: kNoRange
        )
        ModeHUD.shared.showListening(near: caretLineRect(client))
    }

    /// 定案：智慧輸入總開關有開就先交給本機模型去贅字、修標點（像 Typeless），再上屏；沒開就直接上屏
    private func endVoice(_ text: String, client: IMKTextInput) {
        ModeHUD.shared.hide()
        if text.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: kNoRange)
            return
        }
        guard UserDefaults.standard.bool(forKey: SettingKey.smartInput), SmartInput.isRunning else {
            return client.insertText(text, replacementRange: kNoRange)
        }
        // ponytail: 整理中（約 1～3 秒）原文先留在組字區；這時打字會先插入整理結果，再調
        SmartInput.polish(text: text) { polished in
            client.insertText(polished, replacementRange: self.kNoRange)
        }
    }

    private func caretLineRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
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
        // 數字小鍵盤有獨立鍵碼、與注音鍵位無關：永遠當數字放行
        let keypadKeys = [
            kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
            kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
            kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadPlus,
            kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEquals,
        ]
        if keypadKeys.contains(Int(event.keyCode)) { return nil }

        guard let chars = event.characters, chars.count == 1, let ch = chars.first else { return nil }
        if ch == " " { return .space }
        if event.modifierFlags.contains(.shift), ch.isLetter {
            return .englishLiteral(ch)  // Shift+字母：英文直出（大小寫依實際輸出）
        }
        guard ch.isASCII, !ch.isNewline else { return nil }
        // 統一小寫餵大千鍵位表；數字與符號原樣（引擎自行判斷選字／標點／拒收）
        let lower = Character(String(ch).lowercased())
        // 長按（鍵盤自動重複）：交給引擎轉直出英文字母／數字
        return event.isARepeat ? .repeatedCharacter(lower) : .character(lower)
    }

    // MARK: - UI 同步

    private func ensureEngine() -> InputEngine? {
        if engine == nil, let lexicon = LexiconStore.lexicon {
            let created = InputEngine(lexicon: lexicon)
            created.userPhrases = Self.userPhrases
            engine = created
        }
        // 偏好設定即時生效（每次按鍵讀一次 UserDefaults，成本可忽略）
        if let engine {
            let defaults = UserDefaults.standard
            engine.englishDetector = LexiconStore.englishDetector
            engine.englishHintEnabled = defaults.bool(forKey: SettingKey.englishHint)
            engine.fullWidthPunctuation = defaults.bool(forKey: SettingKey.fullWidthPunctuation)
            engine.autoSpacing = defaults.bool(forKey: SettingKey.autoSpacing)
            engine.pageSize = defaults.integer(forKey: SettingKey.pageSize)
            engine.associationsEnabled = defaults.bool(forKey: SettingKey.associations)
            SmartInput.setEnabled(Self.smartInputOn(.aiCompletion) || Self.smartInputOn(.smartCorrection))
            let fuzzy = defaults.bool(forKey: SettingKey.fuzzyReading)
            if engine.fuzzyReadingEnabled != fuzzy { engine.fuzzyReadingEnabled = fuzzy }
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
        requestCompletionIfNeeded(engine, client: client)
        requestCorrectionIfNeeded(engine, client: client)
        if let sheet = engine.sheetView() ?? engine.englishHintView() ?? engine.associationView() {
            var lineRect = NSRect.zero
            client.attributes(forCharacterIndex: sheet.anchorUTF16, lineHeightRectangle: &lineRect)
            CandidatePanel.shared.present(
                sheet, near: lineRect, clientLevel: client.windowLevel(), owner: self
            ) { [weak self] index in
                // 滑鼠點選：跟按對應的鍵一樣走引擎，結果照常寫回 client
                guard let self, let engine = self.engine else { return }
                let output = engine.click(itemAt: index)
                if let commit = output.commitText {
                    client.insertText(commit, replacementRange: self.kNoRange)
                }
                self.syncUI(engine, client: client)
            }
        } else {
            CandidatePanel.shared.dismiss(owner: self)
        }
    }

    private enum SmartFeature { case aiCompletion, smartCorrection }

    /// 智慧輸入的某個功能有沒有開：總開關＋該功能的開關都要打勾
    private static func smartInputOn(_ feature: SmartFeature) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingKey.smartInput) else { return false }
        switch feature {
        case .aiCompletion: return defaults.bool(forKey: SettingKey.aiCompletion)
        case .smartCorrection: return defaults.bool(forKey: SettingKey.smartCorrection)
        }
    }

    /// AI 補句：組好的字變了就（停手後）問一次；結果回來時組字區還是同一句才顯示
    private func requestCompletionIfNeeded(_ engine: InputEngine, client: IMKTextInput) {
        guard Self.smartInputOn(.aiCompletion), let text = engine.completionContext else {
            SmartInput.cancel(.completion)
            Self.lastCompletionRequest = nil
            return
        }
        guard engine.aiCompletion == nil, text != Self.lastCompletionRequest else { return }
        let before = textBeforeComposition(client)
        guard (before + text).filter({ !$0.isWhitespace }).count >= Self.minimumCompletionContext else {
            SmartInput.cancel(.completion)
            return
        }
        Self.lastCompletionRequest = text
        SmartInput.complete(text: text, before: before) { [weak self] completion in
            guard let self, let engine = self.engine, engine.completionContext == text else { return }
            engine.aiCompletion = completion
            self.syncUI(engine, client: client)
        }
    }

    /// AI 校正：組字區變了就（停手後）問一次；回來時組字區還是同一句才套用（只採用同音的改動）
    private func requestCorrectionIfNeeded(_ engine: InputEngine, client: IMKTextInput) {
        guard Self.smartInputOn(.smartCorrection), let target = engine.correctionTarget,
              let grammar = engine.correctionGrammar else {
            SmartInput.cancel(.correction)
            Self.lastCorrectionRequest = nil
            return
        }
        guard target.text != Self.lastCorrectionRequest else { return }
        let before = textBeforeComposition(client)
        guard (before + target.text).filter({ !$0.isWhitespace }).count >= Self.minimumCompletionContext else {
            SmartInput.cancel(.correction)
            Log.general.info("AI 校正：字數不到 \(Self.minimumCompletionContext, privacy: .public) 個，先不問")
            return
        }
        Self.lastCorrectionRequest = target.text
        SmartInput.correct(text: target.text, before: before, grammar: grammar) { [weak self] corrected in
            guard let self, let engine = self.engine else { return }
            guard engine.applyCorrection(corrected, to: target.text) else {
                Log.general.info("AI 校正：沒有改動（沒錯字、不同音或組字區已變）")
                return
            }
            Log.general.info("AI 校正：已改正")
            Self.lastCorrectionRequest = engine.correctionTarget?.text  // 改好的句子不再重問
            self.syncUI(engine, client: client)
        }
    }

    /// 文件裡組字區前面的文字（最多 40 字、只取同一行），給 AI 當上下文；app 不給讀就空字串
    private func textBeforeComposition(_ client: IMKTextInput) -> String {
        let marked = client.markedRange()
        let location = marked.location != NSNotFound ? marked.location : client.selectedRange().location
        guard location != NSNotFound, location > 0 else { return "" }
        let length = min(40, location)
        let text = client.attributedSubstring(from: NSRange(location: location - length, length: length))?.string ?? ""
        return text.components(separatedBy: .newlines).last ?? ""
    }

    private func setMarked(
        _ preedit: InputEngine.Preedit,
        client: IMKTextInput,
        replacing documentRange: NSRange? = nil
    ) {
        let attributed = NSMutableAttributedString()
        var location = 0
        for piece in preedit.pieces {
            let style: Int
            switch piece.style {
            case .converted: style = Int(kTSMHiliteConvertedText)
            case .active: style = Int(kTSMHiliteSelectedConvertedText)
            case .raw: style = Int(kTSMHiliteSelectedRawText)
            case .caret: style = Int(kTSMHiliteRawText)
            }
            let range = NSRange(location: location, length: piece.text.utf16.count)
            let attrs = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any]
                ?? [.underlineStyle: NSUnderlineStyle.single.rawValue]
            attributed.append(NSAttributedString(string: piece.text, attributes: attrs))
            location += piece.text.utf16.count
        }
        client.setMarkedText(
            attributed,
            // 有活動詞就以反白呈現（零長度游標在很多 app 看不出來）
            selectionRange: preedit.activeRangeUTF16
                .map { NSRange(location: $0.start, length: $0.length) }
                ?? NSRange(location: preedit.caretUTF16, length: 0),
            replacementRange: documentRange ?? kNoRange
        )
    }
}
