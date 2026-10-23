import Foundation

/// InputEngine 的組字區、候選窗、提示列要顯示什麼（純讀狀態，不改東西）。狀態都在 InputEngine.swift。
extension InputEngine {

    // MARK: - 顯示

    public func preedit() -> Preedit {
        let texts = elementTexts()
        let active = anchorSegment()
        var pieces: [Preedit.Piece] = []
        var caret = 0

        func append(_ text: String, _ style: Preedit.Style) {
            guard !text.isEmpty else { return }
            if let last = pieces.last, last.style == style {
                pieces[pieces.count - 1] = Preedit.Piece(text: last.text + text, style: style)
            } else {
                pieces.append(Preedit.Piece(text: text, style: style))
            }
        }

        // 游標在句中時畫出插入記號；句尾不畫（app 自己的游標就在那，畫了反而多餘），
        // 正在打注音時也不畫（注音本身就長在游標處，位置一目了然）
        let showCaretMark = composer.isEmpty && cursor < elements.count
        var caretMarkOffset: Int?

        for index in 0..<elements.count {
            if index == cursor {
                append(composingText, .raw)
                caret = pieces.reduce(0) { $0 + $1.text.utf16.count }
                if showCaretMark {
                    caretMarkOffset = caret
                    append(Self.caretMark, .caret)
                }
            }
            let style: Preedit.Style =
                (active != nil && index >= active!.start && index < active!.end) ? .active : .converted
            append(texts[index], style)
        }
        if cursor == elements.count {
            append(composingText, .raw)
            caret = pieces.reduce(0) { $0 + $1.text.utf16.count }
        }
        // 游標所在詞的反白範圍：只在沒有組字中的注音時提供，
        // 這樣使用者用方向鍵回頭改字時看得見自己停在哪個詞
        // 反白「游標所在的那個字」而非整個詞：先前框整個詞，導致在多字詞
        // 內移動游標時畫面完全沒變化，使用者看不出游標在哪。
        var activeRange: (start: Int, length: Int)?
        if composer.isEmpty, !elements.isEmpty {
            let index = max(0, min(cursor - 1, elements.count - 1))
            let texts = elementTexts()
            var start = texts[..<index].reduce(0) { $0 + $1.utf16.count }
            let width = texts[index].utf16.count
            if let offset = caretMarkOffset, offset <= start {
                start += Self.caretMark.utf16.count  // 記號插在前面，反白起點跟著移
            }
            if width > 0 { activeRange = (start: start, length: width) }
        }
        return Preedit(pieces: pieces, caretUTF16: caret, activeRangeUTF16: activeRange)
    }

    public func sheetView() -> SheetView? {
        if let bilingual {
            let items = bilingual.choices.enumerated().map { offset, choice in
                let value: String
                switch choice {
                case .english(let text): value = text
                case .tone1(let display): value = display
                }
                return SheetView.Item(label: "\(offset + 1)", value: value)
            }
            let current = preedit()
            return SheetView(
                items: items,
                highlightedInPage: bilingual.highlighted,
                pageIndex: 0,
                pageCount: 1,
                anchorUTF16: current.caretUTF16 - composingText.utf16.count
            )
        }
        guard let sheet, !sheet.all.isEmpty else { return nil }
        let pageCount = (sheet.all.count + pageSize - 1) / pageSize
        let page = sheet.highlighted / pageSize
        let range = (page * pageSize)..<min(sheet.all.count, (page + 1) * pageSize)
        let items = sheet.all[range].enumerated().map { offset, segment in
            SheetView.Item(label: "\(offset + 1)", value: segment.value)
        }
        let anchorUTF16 = elementTexts()[..<min(sheet.anchor, elements.count)]
            .reduce(0) { $0 + $1.utf16.count }
        return SheetView(
            items: items,
            highlightedInPage: sheet.highlighted - page * pageSize,
            pageIndex: page,
            pageCount: pageCount,
            anchorUTF16: anchorUTF16
        )
    }

    /// 聯想詞提示的呈現（橫排、標 1〜5；按了 Tab 第一個反白）
    public func associationView() -> SheetView? {
        let shown = visibleAssociations
        let completion = visibleCompletion
        guard !shown.isEmpty || completion != nil else { return nil }
        var items = shown.enumerated().map { SheetView.Item(label: "\($0.offset + 1)", value: $0.element) }
        if let completion { items.insert(SheetView.Item(label: "✨→", value: completion), at: 0) }
        return SheetView(
            items: items,
            highlightedInPage: associationArmed ? (completion == nil ? 0 : 1) : -1, pageIndex: 0, pageCount: 1,
            // 對齊最後一個詞的開頭（同英文提示）。組字文字的「結尾」位置很多 app 回報不出來，窗會跑掉
            anchorUTF16: walked.last.map { elementTexts()[..<$0.start].reduce(0) { $0 + $1.utf16.count } } ?? 0,
            horizontal: true
        )
    }

    /// 英文／數字提示的候選窗呈現（單一項目、⇥ 標籤、不搶按鍵）
    public func englishHintView() -> SheetView? {
        guard sheet == nil, bilingual == nil else { return nil }
        let numeric = numericRaw.count >= 2 ? numberHint : nil
        guard let hint = numeric ?? englishHint else { return nil }
        let current = preedit()
        // 英文提示只跨組字中的注音；數字提示還要往回涵蓋這串期間已組出的字
        var width = composingText.utf16.count
        if numeric != nil {
            let texts = elementTexts()
            for index in max(0, cursor - numericElements)..<cursor {
                width += texts[index].utf16.count
            }
        }
        return SheetView(
            items: [SheetView.Item(label: "⇥", value: hint)],
            highlightedInPage: -1,
            pageIndex: 0,
            pageCount: 1,
            anchorUTF16: max(0, current.caretUTF16 - width)
        )
    }
}
