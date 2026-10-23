import Foundation

/// InputEngine 的候選窗：選字、符號表、中英並列。狀態都在 InputEngine.swift。
extension InputEngine {

    // MARK: - 候選窗

    func handleInSheet(_ key: KeyInput) -> Output? {
        guard var current = sheet else { return nil }
        switch key {
        case .character(let ch):
            if let digit = ch.wholeNumberValue, (1...9).contains(digit) {
                let page = current.highlighted / pageSize
                let index = page * pageSize + digit - 1
                // 只選本頁（每頁 7 字時，8、9 不該跳去選下一頁的字）
                if digit <= pageSize, index < current.all.count { return choose(current.all[index], kind: current.kind) }
                return .consumed
            }
            if ch == "`", current.kind == .symbols {
                return choose(DecodedSegment(start: cursor, length: 0, value: "`", reading: nil), kind: .symbols)  // 連按兩下＝要 ` 本身
            }
            // 繼續打字：關窗、照常組字
            sheet = nil
            return nil
        // 直式清單導航：↑↓ 逐項、←→ 與 PgUp/PgDn 翻頁、空白循環
        case .space:
            current.highlighted = (current.highlighted + 1) % current.all.count
            sheet = current
            return .consumed
        case .arrowDown:
            current.highlighted = min(current.all.count - 1, current.highlighted + 1)
            sheet = current
            return .consumed
        case .arrowUp:
            current.highlighted = max(0, current.highlighted - 1)
            sheet = current
            return .consumed
        case .arrowRight, .pageDown, .tab:
            current.highlighted = min(current.all.count - 1, current.highlighted + pageSize)
            sheet = current
            return .consumed
        case .arrowLeft, .pageUp:
            current.highlighted = max(0, current.highlighted - pageSize)
            sheet = current
            return .consumed
        case .enter:
            return choose(current.all[current.highlighted], kind: current.kind)
        case .escape:
            sheet = nil
            return .consumed
        case .backspace:
            sheet = nil
            return current.kind == .symbols ? .consumed : nil  // 符號表退格只收窗
        case .shiftBackspace:
            sheet = nil
            return nil
        case .englishLiteral:
            sheet = nil
            return nil
        case .repeatedCharacter:
            return .consumed  // 候選窗開啟時忽略長按重複，避免連續選字
        }
    }

    // MARK: - 中英並列選字

    func openBilingualSheet() {
        guard let raw = englishHint else { return }
        var choices: [BilingualChoice] = []
        var seen = Set<String>()
        if let expansion = shortcuts.expansion(for: raw) { choices.append(.english(expansion)) }  // 快捷文字排第一
        for variant in [raw, raw.prefix(1).uppercased() + raw.dropFirst(), raw.uppercased()]
        where seen.insert(variant).inserted {
            choices.append(.english(variant))
        }
        // 一聲中文字並列：使用者按空白原本想要的那個字
        var syllable = composer.syllable
        syllable.tone = .tone1
        let tone1Display = lexicon.unigrams(syllable.canonical).first?.value ?? syllable.display
        choices.append(.tone1(display: tone1Display))
        bilingual = BilingualSheet(choices: choices)
    }

    func handleInBilingual(_ key: KeyInput) -> Output? {
        guard var current = bilingual else { return nil }
        switch key {
        case .character(let ch):
            if let digit = ch.wholeNumberValue, (1...current.choices.count).contains(digit) {
                selectBilingual(current.choices[digit - 1])
                return .consumed
            }
            // 繼續打字＝先上反白項，再照常處理這個鍵（不然 google 會被接著打的注音吃掉）
            selectBilingual(current.choices[current.highlighted])
            return nil
        case .englishLiteral:
            selectBilingual(current.choices[current.highlighted])
            return nil
        case .space, .arrowDown:
            current.highlighted = (current.highlighted + 1) % current.choices.count
            bilingual = current
            return .consumed
        case .arrowUp:
            current.highlighted = (current.highlighted - 1 + current.choices.count) % current.choices.count
            bilingual = current
            return .consumed
        case .enter:
            selectBilingual(current.choices[current.highlighted])
            return .consumed
        case .tab:
            // Tab 維持快速上英文：選反白項，反白在一聲字上則取第一個英文
            if case .tone1 = current.choices[current.highlighted] {
                selectBilingual(current.choices[0])
            } else {
                selectBilingual(current.choices[current.highlighted])
            }
            return .consumed
        case .escape:
            bilingual = nil  // 收窗、保留組字中的注音
            return .consumed
        case .backspace:
            // 退一個字母、窗不關（還像英文就用新字串重開）
            bilingual = nil
            _ = composer.backspace()
            openBilingualSheet()
            return .consumed
        default:
            bilingual = nil
            return nil
        }
    }

    func selectBilingual(_ choice: BilingualChoice) {
        bilingual = nil
        switch choice {
        case .english(let text):
            replaceComposer(with: text)
        case .tone1:
            _ = handleCharacter(" ")  // 照原本的空白行為組一聲字
        }
    }

    func openSheet() {
        guard let anchor = anchorSegment() else { return }
        // 數字（Tab 確認過的 1234）：列出千分位、大寫、國字等寫法
        if anchor.reading == nil {
            let forms = NumberForms.forms(of: anchor.value)
            guard !forms.isEmpty else { return }
            sheet = Sheet(
                all: forms.map { DecodedSegment(start: anchor.start, length: 1, value: $0, reading: nil) },
                anchor: anchor.start, highlighted: 0, kind: .number(index: anchor.start)
            )
            return
        }
        var all = decoder.candidateSegments(elements, start: anchor.start, after: previousWord(before: anchor.start))
        guard !all.isEmpty else { return }
        let highlighted = all.firstIndex { $0.value == anchor.value && $0.length == anchor.length } ?? 0
        // 今天、現在…：日期時間寫法緊接在目前的詞後面，第一頁就看得到
        // ponytail: 只認整個詞剛好是「今天」的段；被併進長詞（今天晚上）時不出現
        if let reading = anchor.reading {
            let dates = DateMacro.forms(for: reading).map {
                DecodedSegment(start: anchor.start, length: anchor.length, value: $0, reading: reading)
            }
            all.insert(contentsOf: dates, at: highlighted + 1)
        }
        sheet = Sheet(all: all, anchor: anchor.start, highlighted: highlighted)
    }

    func openSymbolSheet() {
        sheet = Sheet(
            all: SymbolTable.symbols.map { DecodedSegment(start: cursor, length: 0, value: $0, reading: nil) },
            anchor: cursor, highlighted: 0, kind: .symbols
        )
    }

    func choose(_ segment: DecodedSegment, kind: Sheet.Kind) -> Output {
        switch kind {
        case .words:
            select(segment)
        case .symbols:
            sheet = nil
            if elements.isEmpty { return Output(handled: true, commitText: segment.value) }
            insertLiteral(segment.value)
        case .number(let index):
            sheet = nil
            elements[index] = .literal(segment.value)
            rewalk()
        }
        return .consumed
    }

    func select(_ segment: DecodedSegment) {
        var segment = segment
        // 選的就是原本組出來的字：只是確認，不算改字
        segment.keepsOriginal = walked.contains {
            $0.start == segment.start && $0.length == segment.length && $0.value == segment.value
        }
        pins.removeAll { $0.start < segment.end && segment.start < $0.end }
        pins.append(segment)
        if let reading = segment.reading, !DateMacro.forms(for: reading).contains(segment.value) {
            userPhrases?.bump(reading: reading, value: segment.value, after: previousWord(before: segment.start))
        }
        rewalk()
        cursor = min(segment.end + 1, elements.count)  // 指向下一個字（游標＝其右邊）
        sheet = nil
    }

    /// 這個位置前面那個詞：組字區裡的前一段；在句首就用游標前已上屏的前文（沒有就 "^"）
    func previousWord(before start: Int) -> String {
        walked.first { $0.end == start }?.value ?? decoder.startKey
    }
}
