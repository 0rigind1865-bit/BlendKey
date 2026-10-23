import Foundation

/// InputEngine 的一般按鍵：注音、長按、英文接續段、數字串、黏英數符號。狀態都在 InputEngine.swift。
extension InputEngine {

    // MARK: - 字元

    /// 長按（自動重複）：把剛被吃成注音組件的鍵退掉、改為直出原始字元，
    /// 並開始英文接續段（長按開頭＝要打小寫英文）。
    /// 聲調鍵除外（按下當下音節已完成，undo 語意混亂，且空組字區時聲調鍵本來就放行）。
    func handleLongPress(_ ch: Character) -> Output {
        if longPressKey == ch { return .consumed }  // 已轉換，吞掉後續重複
        if composer.rawKeys.last == ch,
           let component = DachenLayout.component(for: ch),
           !component.isTone {
            _ = composer.backspace()
            insertLiteral(String(ch))
            longPressKey = ch
            if ch.isLetter { isInLiteralRun = true }  // 數字長按維持單發
            return .consumed
        }
        return isIdle ? .ignored : .consumed
    }

    /// 英文段中的一般按鍵：原樣直出；但若偵測到其實在打注音（兩個查得到的音節、
    /// 含數字聲調），就把這串已直出的按鍵退掉、結束英文段、改走注音組字
    func handleLiteralRunKey(_ ch: Character) -> Output {
        guard englishHintEnabled, let keys = literalRunDetector.feed(ch) else {
            insertLiteral(String(ch))
            return .consumed
        }
        // 最後一鍵還沒直出；前面的必須確實是剛直出的那幾個字元才動手
        let emitted = keys.dropLast().map { Element.literal(String($0)) }
        guard cursor >= emitted.count,
              Array(elements[(cursor - emitted.count)..<cursor]) == emitted else {
            insertLiteral(String(ch))
            return .consumed
        }
        for _ in emitted { removeElement(at: cursor - 1) }
        isInLiteralRun = false
        for key in keys { _ = handle(key == " " ? .space : .character(key)) }
        return .consumed
    }

    /// 數字鍵串追蹤：組字器空著時以數字鍵起頭就開始記，之後連續的
    /// 數字鍵（含 . , -，它們同時是 ㄡㄝㄦ）一路累積；出現其他鍵即取消。
    func trackNumeric(_ ch: Character, composerWasEmpty: Bool) {
        if !numericRaw.isEmpty {
            // 數字起頭之後，字母與 . , - 都算同一串（1mm、0.4mm、5v）
            if ch.isLetter || ch.isNumber || ".,-".contains(ch) {
                numericRaw.append(ch)
            } else {
                cancelNumericRun()
            }
        } else if composerWasEmpty, ch.isNumber {
            numericRaw = String(ch)
        }
    }

    /// 組字中的音節標上一聲後，詞庫查得到嗎（空白鍵讓路給數字的判準）
    func tone1FormsKnownReading() -> Bool {
        let syllable = composer.syllable
        // 只有 ㄓㄔㄕㄖㄗㄘㄙ 能單獨成音節（知、吃、是、日、資、次、思）；
        // 其餘聲母單獨出現不是字——詞庫雖收了「ㄅ」這個注音符號本身，不能當數。
        let standalone: Set<Syllable.Initial> = [.zh, .ch, .sh, .r, .z, .c, .s]
        guard syllable.medial != nil || syllable.final != nil
                || syllable.initial.map(standalone.contains) == true else { return false }
        var withTone = syllable
        withTone.tone = .tone1
        return !lexicon.unigrams(withTone.canonical).isEmpty
    }

    func cancelNumericRun() {
        numericRaw = ""
        numericElements = 0
    }

    /// 把這串數字期間組出的注音全數退掉，改為直出數字文字
    /// 組字中的數字／英文提示收成文字（Tab、黏英數符號、Enter 展開縮寫共用）。
    /// - Returns: 有沒有提示可收
    @discardableResult
    func acceptHint(expandingShortcut: Bool = false) -> Bool {
        if numberHint != nil {
            acceptNumber()
            return true
        }
        guard let raw = englishHint else { return false }
        replaceComposer(with: expandingShortcut ? shortcuts.expansion(for: raw) ?? raw : raw)
        return true
    }

    /// 丟掉組字中的注音按鍵，改放一段直出文字
    func replaceComposer(with text: String) {
        composer.clear()
        insertLiteral(text)
    }

    func acceptNumber() {
        guard let number = numberHint else { return }
        composer.clear()
        for _ in 0..<min(numericElements, cursor) {
            removeElement(at: cursor - 1)
        }
        insertLiteral(number)
        cancelNumericRun()
    }

    func handleCharacter(_ ch: Character) -> Output {
        let composerWasEmpty = composer.isEmpty
        let keysBefore = composer.rawKeys
        let overwritten = composer.overwriteCount > 0
        switch composer.press(ch) {
        case .absorbed:
            trackNumeric(ch, composerWasEmpty: composerWasEmpty)
            return .consumed
        case .composed(let syllable):
            if let (word, rest) = splitLiteralPrefix(keysBefore + String(ch), composed: syllable, overwritten: overwritten) {
                cancelNumericRun()
                insertLiteral(word)
                insertReading(rest)
                return .consumed
            }
            trackNumeric(ch, composerWasEmpty: composerWasEmpty)
            if !numericRaw.isEmpty { numericElements += 1 }
            insertReading(syllable)
            return .consumed
        case .rejected:
            // 3/4/6/7 是聲調鍵，打在空音節上會被拒——那它就是使用者要的數字。
            // 納入數字串（4mm、60fps 才起得了頭），並直接放進組字區。
            if ch.isNumber, composer.isEmpty {
                trackNumeric(ch, composerWasEmpty: true)
                insertLiteral(String(ch))
                if !numericRaw.isEmpty { numericElements += 1 }
                return .consumed
            }
            if !composer.isEmpty {
                if let output = acceptHintThenSymbol(ch) { return output }
                cancelNumericRun()
                return .consumed  // 打錯鍵不打斷組字
            }
            cancelNumericRun()
            if ch == "`" { openSymbolSheet(); return .consumed }
            if fullWidthPunctuation, let punct = Punctuation.fullWidth(ch) {
                if elements.isEmpty { return Output(handled: true, commitText: punct) }
                insertLiteral(punct)
                return .consumed
            }
            if elements.isEmpty { return .ignored }
            // 組字區有內容時打到非注音鍵：先上屏，再讓按鍵原樣送給應用程式
            return Output(handled: false, commitText: flush())
        }
    }

    /// 黏在英文／數字後面的符號（snake_case、I'll、10:30、a@b）：半形直出、之後的字母原樣接續；
    /// 句末標點與括號（google? → google？）則照常全形
    static let stickySymbols: Set<Character> = ["_", "'", ":", "@", "#", "$", "%", "^", "&", "*", "=", "+", "~", "|", "\\"]

    /// 組字中偵測到英文／數字時打到符號鍵：先把提示收成文字，再處理符號。非提示狀態回 nil
    func acceptHintThenSymbol(_ ch: Character) -> Output? {
        guard Self.stickySymbols.contains(ch) || Punctuation.fullWidth(ch) != nil else { return nil }
        guard acceptHint() else { return nil }
        if Self.stickySymbols.contains(ch) {
            insertLiteral(String(ch))
            isInLiteralRun = true
            return .consumed
        }
        if fullWidthPunctuation, let punct = Punctuation.fullWidth(ch) {
            insertLiteral(punct)
            return .consumed
        }
        return Output(handled: false, commitText: flush())
    }

    /// 組字區只有英文／數字直出的文字（沒有任何注音）
    var isPureLiteral: Bool {
        composer.isEmpty && !elements.isEmpty && elements.allSatisfy { if case .literal = $0 { return true } else { return false } }
    }

    /// 打完英文或數字沒按 Tab 就接著打注音：鍵全混進同一個音節（push＋上＝ㄕㄧㄤˋ、150＋個＝ㄍㄜˋ，
    /// 前面的鍵被後面的覆寫掉）。這時拆成「英文詞／數字＋剩下組出的音節」，前段越長越優先。
    /// 只在「整串查不到」或「中途有覆寫」時才試——正常打注音兩者都不會發生。
    /// ponytail: 一聲（空白收尾）且整串都是字母時會先被英文提示攔去開中英並列窗，那條路不拆
    func splitLiteralPrefix(_ keys: String, composed: Syllable, overwritten: Bool) -> (String, Syllable)? {
        let wholeKnown = !lexicon.unigrams(composed.canonical).isEmpty
        guard overwritten || !wholeKnown else { return nil }
        let chars = Array(keys)
        // 剩下至少「一個注音＋聲調」兩鍵
        for cut in stride(from: chars.count - 2, through: 1, by: -1) {
            let prefix = String(chars[..<cut])
            let isNumber = prefix.first!.isNumber && prefix.last!.isNumber
                && prefix.allSatisfy { $0.isNumber || ".,".contains($0) }
            // 整串本來查得到（只是有覆寫）時，英文詞要 3 字母以上，避免把改鍵誤判成英文
            let isWord = englishHintEnabled && cut >= (wholeKnown ? 3 : 2)
                && prefix.allSatisfy { $0.isLetter || $0.isNumber }
                && englishDetector?.isWord(prefix) == true
            guard isNumber || isWord else { continue }
            var rest = SyllableComposer()
            let tail = chars[cut...]
            // 中途就組成音節（夾了聲調鍵）＝不是「一個音節」，跳過
            guard tail.dropLast().allSatisfy({ rest.press($0) == .absorbed }),
                  case .composed(let syllable) = rest.press(tail.last!),
                  !lexicon.unigrams(syllable.canonical).isEmpty else { continue }
            return (prefix, syllable)
        }
        return nil
    }
}
