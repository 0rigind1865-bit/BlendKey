import Foundation

/// InputEngine 的聯想詞、AI 補句、AI 校正。狀態都在 InputEngine.swift。
extension InputEngine {

    // MARK: - 聯想詞

    /// 目前該顯示的聯想詞（空＝不顯示）。其他視窗或提示開著時讓路。
    /// 跟著最後一個詞即時更新；打注音打到一半也維持顯示，不會每個音節閃一下。
    var visibleAssociations: [String] {
        guard associationsEnabled, suggestionsAllowed, let store = userPhrases, let last = walked.last
        else { return [] }
        return store.nextWords(after: last.value, limit: 5)
    }

    var visibleCompletion: String? { suggestionsAllowed ? aiCompletion : nil }

    /// 提示列（聯想詞、AI 補句）可以出現的時機：其他視窗或提示開著時讓路，
    /// 游標回頭改字時不提示
    var suggestionsAllowed: Bool {
        sheet == nil && bilingual == nil && !isInLiteralRun && englishHint == nil && numberHint == nil
            && cursor == elements.count && !elements.isEmpty
    }

    /// AI 校正的對象：組好的字與每個字的注音（標點等直出的單字為 nil＝不能改）。
    /// 每個元素剛好一個字時才提供（夾了 google 這種多字的英文就不校正），
    /// 游標要在句尾（回頭改字時不動它）。
    public var correctionTarget: (text: String, readings: [String?])? {
        guard composer.isEmpty, sheet == nil, bilingual == nil, !isInLiteralRun,
              !elements.isEmpty, cursor == elements.count else { return nil }
        let texts = elementTexts()
        guard texts.allSatisfy({ $0.count == 1 }) else { return nil }
        return (texts.joined(), elements.map(\.readingValue))
    }

    /// AI 校正的文法限制（llama.cpp GBNF）：每一格只能是原字或同讀音的常用字（前 12 個），
    /// 標點等直出的字只能原樣。模型根本寫不出不同音的字，就不會白問一次（實驗 H：修 5、改壞 0）。
    public var correctionGrammar: String? {
        guard let target = correctionTarget else { return nil }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let slots = zip(target.text, target.readings).map { char, reading -> String in
            var choices = [String(char)]
            for unigram in reading.map({ lexicon.unigrams($0) }) ?? [] where unigram.value.count == 1 {
                guard choices.count < 13 else { break }
                if !choices.contains(unigram.value) { choices.append(unigram.value) }
            }
            return "(" + choices.map(quoted).joined(separator: " | ") + ")"
        }
        return "root ::= " + slots.joined(separator: " ")
    }

    /// 套用 AI 校正：組字區還是同一句、字數一樣才套用；只採用「同音」的改動（保險），
    /// 改到的詞以 pin 固定（跟使用者自己選字一樣，按 ↓ 還能改回來，但不記入選字學習）。
    /// - Returns: 有沒有真的改到字
    @discardableResult
    public func applyCorrection(_ corrected: String, to original: String) -> Bool {
        guard let target = correctionTarget, target.text == original, corrected.count == original.count
        else { return false }
        let old = Array(original), proposed = Array(corrected)
        var chars = old
        for index in old.indices where proposed[index] != old[index] {
            guard let reading = target.readings[index] else { continue }  // 標點等直出的字不改
            let candidate = String(proposed[index])
            if lexicon.unigrams(reading).contains(where: { $0.value == candidate }) {
                chars[index] = proposed[index]
            }
        }
        guard chars != old else { return false }
        for segment in walked where segment.reading != nil
            && (segment.start..<segment.end).contains(where: { chars[$0] != old[$0] }) {
            pins.removeAll { $0.start < segment.end && segment.start < $0.end }
            pins.append(DecodedSegment(
                start: segment.start, length: segment.length,
                value: String(chars[segment.start..<segment.end]), reading: segment.reading, keepsOriginal: true
            ))
        }
        rewalk()
        return true
    }

    /// 要給 AI 接下去的「目前組好的字」：注音打完一個音節、游標在句尾時才有值
    public var completionContext: String? {
        guard composer.isEmpty, suggestionsAllowed else { return nil }
        return elementTexts().joined()
    }

    func handleArmedAssociations(_ key: KeyInput) -> Output? {
        associationArmed = false
        let shown = visibleAssociations
        guard !shown.isEmpty else { return nil }
        switch key {
        case .character(let ch):
            guard let digit = ch.wholeNumberValue, (1...shown.count).contains(digit) else { return nil }
            acceptAssociation(shown[digit - 1])
            return .consumed
        case .tab:
            acceptAssociation(shown[0])  // Tab 兩下＝第一個
            return .consumed
        case .escape:
            return .consumed  // 只取消選擇，組字區不動
        default:
            return nil  // 其他鍵：取消選擇、照常處理
        }
    }

    /// 打到一半的注音當作就是要打這個詞，換成它
    /// ponytail: 以直出片段插入（接續表只存詞、不存讀音），插入後不能再用 ↓ 改字；要能改得在接續表存讀音
    func acceptAssociation(_ word: String) {
        composer.clear()
        cancelNumericRun()
        associationArmed = false
        insertLiteral(word)
    }

    /// 滑鼠點了小窗的第 index 項（本頁內，從 0 起）：跟按對應的鍵一樣
    public func click(itemAt index: Int) -> Output {
        if sheet != nil || bilingual != nil {
            return handle(.character(Character(String(index + 1))))
        }
        if englishHintView() != nil { return handle(.tab) }
        var shown = visibleAssociations
        if let completion = visibleCompletion { shown.insert(completion, at: 0) }  // 同提示列的順序
        guard shown.indices.contains(index) else { return .ignored }
        acceptAssociation(shown[index])
        return .consumed
    }
}
