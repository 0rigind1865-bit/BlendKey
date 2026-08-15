/// 輸入引擎：組字區狀態機。吃 KeyInput、維護元素串／游標／pin／候選窗，
/// 產出上屏文字與組字區顯示。IMK 殼層與 CLI 共用，全邏輯可單元測試。
public final class InputEngine {

    // MARK: - 對外型別

    public struct Output: Equatable, Sendable {
        public var handled: Bool
        public var commitText: String?

        static let ignored = Output(handled: false, commitText: nil)
        static let consumed = Output(handled: true, commitText: nil)
    }

    public struct Preedit: Equatable, Sendable {
        public enum Style: Equatable, Sendable {
            case converted  // 已組句文字
            case active     // 游標所在的詞（按 ↓ 會開它的候選）
            case raw        // 組字中的注音
        }
        public struct Piece: Equatable, Sendable {
            public let text: String
            public let style: Style
        }
        public let pieces: [Piece]
        public let caretUTF16: Int

        public var text: String { pieces.map(\.text).joined() }
        public var isEmpty: Bool { pieces.isEmpty }
    }

    public struct SheetView: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let label: String   // 「1」〜「9」
            public let value: String
        }
        public let items: [Item]
        public let highlightedInPage: Int
        public let pageIndex: Int
        public let pageCount: Int
        /// 正在改字的詞在組字區裡的起點（UTF-16），候選窗對齊這裡
        public let anchorUTF16: Int
    }

    // MARK: - 狀態

    private let decoder: SentenceDecoder
    private let pageSize = 9

    private var elements: [Element] = []
    private var cursor = 0  // 元素邊界位置 0...elements.count
    private var pins: [DecodedSegment] = []
    private var composer = SyllableComposer()
    private var walked: [DecodedSegment] = []

    private struct Sheet {
        var all: [DecodedSegment]
        var anchor: Int
        var highlighted: Int
    }
    private var sheet: Sheet?

    /// 全形標點開關（M4 接偏好設定）
    public var fullWidthPunctuation = true
    /// 英文詞偵測器（載妥後注入；nil 時不做自動偵測）
    public var englishDetector: EnglishDetector?

    public init(lexicon: Lexicon) {
        decoder = SentenceDecoder(lexicon: lexicon)
    }

    public var isIdle: Bool { elements.isEmpty && composer.isEmpty }

    /// 組字中的原始按鍵看起來是英文時，提供 Tab 直接上英文的提示。
    /// 兩個訊號：命中英文詞典，或注音槽位被反覆覆寫（打英文的特徵）。
    public var englishHint: String? {
        let raw = composer.rawKeys
        guard raw.count >= 3, raw.allSatisfy(\.isLetter) else { return nil }
        if let detector = englishDetector, detector.isWord(raw) { return raw }
        if raw.count >= 4, composer.overwriteCount >= 2 { return raw }
        return nil
    }

    // MARK: - 事件入口

    public func handle(_ key: KeyInput) -> Output {
        if sheet != nil, let output = handleInSheet(key) {
            return output
        }
        switch key {
        case .character(let ch):
            return handleCharacter(ch)
        case .englishLiteral(let ch):
            composer.clear()
            insertLiteral(String(ch))
            return .consumed
        case .space:
            if !composer.isEmpty { return handleCharacter(" ") }
            if !elements.isEmpty { openSheet(); return .consumed }
            return .ignored
        case .enter:
            return flushOutput()
        case .escape:
            if !composer.isEmpty { composer.clear(); return .consumed }
            if !elements.isEmpty { reset(); return .consumed }
            return .ignored
        case .backspace:
            if !composer.isEmpty {
                _ = composer.backspace()
                return .consumed
            }
            guard cursor > 0 else { return elements.isEmpty ? .ignored : .consumed }
            removeElement(at: cursor - 1)
            return .consumed
        case .arrowLeft:
            guard !isIdle else { return .ignored }
            if composer.isEmpty { cursor = max(0, cursor - 1) }
            return .consumed
        case .arrowRight:
            guard !isIdle else { return .ignored }
            if composer.isEmpty { cursor = min(elements.count, cursor + 1) }
            return .consumed
        case .arrowDown:
            guard !elements.isEmpty else { return .ignored }
            if composer.isEmpty { openSheet() }  // 組字中不開候選窗
            return .consumed
        case .tab:
            if let hint = englishHint {
                composer.clear()
                insertLiteral(hint)
                return .consumed
            }
            return isIdle ? .ignored : .consumed
        case .arrowUp, .pageUp, .pageDown:
            return isIdle ? .ignored : .consumed
        }
    }

    /// 失焦／換行時把組字區內容送出
    public func flush() -> String? {
        let text = committedText()
        reset()
        return text.isEmpty ? nil : text
    }

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

        for index in 0..<elements.count {
            if index == cursor {
                append(composer.display, .raw)
                caret = pieces.reduce(0) { $0 + $1.text.utf16.count }
            }
            let style: Preedit.Style =
                (active != nil && index >= active!.start && index < active!.end) ? .active : .converted
            append(texts[index], style)
        }
        if cursor == elements.count {
            append(composer.display, .raw)
            caret = pieces.reduce(0) { $0 + $1.text.utf16.count }
        }
        return Preedit(pieces: pieces, caretUTF16: caret)
    }

    public func sheetView() -> SheetView? {
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

    /// 英文提示的候選窗呈現（單一項目、⇥ 標籤、不搶按鍵）
    public func englishHintView() -> SheetView? {
        guard sheet == nil, let hint = englishHint else { return nil }
        let current = preedit()
        return SheetView(
            items: [SheetView.Item(label: "⇥", value: hint)],
            highlightedInPage: -1,
            pageIndex: 0,
            pageCount: 1,
            anchorUTF16: current.caretUTF16 - composer.display.utf16.count
        )
    }

    // MARK: - 字元與候選窗

    private func handleCharacter(_ ch: Character) -> Output {
        switch composer.press(ch) {
        case .absorbed:
            return .consumed
        case .composed(let syllable):
            insertReading(syllable)
            return .consumed
        case .rejected:
            if !composer.isEmpty { return .consumed }  // 打錯鍵不打斷組字
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

    private func handleInSheet(_ key: KeyInput) -> Output? {
        guard var current = sheet else { return nil }
        switch key {
        case .character(let ch):
            if let digit = ch.wholeNumberValue, (1...9).contains(digit) {
                let page = current.highlighted / pageSize
                let index = page * pageSize + digit - 1
                if index < current.all.count { select(current.all[index]) }
                return .consumed
            }
            // 繼續打字：關窗、照常組字
            sheet = nil
            return nil
        case .space, .arrowRight:
            current.highlighted = (current.highlighted + 1) % current.all.count
            sheet = current
            return .consumed
        case .arrowLeft:
            current.highlighted = (current.highlighted - 1 + current.all.count) % current.all.count
            sheet = current
            return .consumed
        case .arrowDown, .pageDown, .tab:
            current.highlighted = min(current.all.count - 1, current.highlighted + pageSize)
            sheet = current
            return .consumed
        case .arrowUp, .pageUp:
            current.highlighted = max(0, current.highlighted - pageSize)
            sheet = current
            return .consumed
        case .enter:
            select(current.all[current.highlighted])
            return .consumed
        case .escape:
            sheet = nil
            return .consumed
        case .backspace:
            sheet = nil
            return nil
        case .englishLiteral:
            sheet = nil
            return nil
        }
    }

    private func openSheet() {
        guard let anchor = anchorSegment() else { return }
        let all = decoder.candidateSegments(elements, start: anchor.start)
        guard !all.isEmpty else { return }
        let highlighted = all.firstIndex { $0.value == anchor.value && $0.length == anchor.length } ?? 0
        sheet = Sheet(all: all, anchor: anchor.start, highlighted: highlighted)
    }

    private func select(_ segment: DecodedSegment) {
        pins.removeAll { $0.start < segment.end && segment.start < $0.end }
        pins.append(segment)
        rewalk()
        cursor = min(segment.end, elements.count)
        sheet = nil
    }

    // MARK: - 元素操作

    private func insertReading(_ syllable: Syllable) {
        insert(.reading(syllable.canonical))
    }

    private func insertLiteral(_ text: String) {
        insert(.literal(text))
    }

    private func insert(_ element: Element) {
        pins = pins.compactMap { pin in
            if pin.end <= cursor { return pin }
            if pin.start >= cursor {
                return DecodedSegment(start: pin.start + 1, length: pin.length, value: pin.value, reading: pin.reading)
            }
            return nil  // 插入點落在 pin 中間：拆掉
        }
        elements.insert(element, at: cursor)
        cursor += 1
        rewalk()
    }

    private func removeElement(at index: Int) {
        pins = pins.compactMap { pin in
            if pin.end <= index { return pin }
            if pin.start > index {
                return DecodedSegment(start: pin.start - 1, length: pin.length, value: pin.value, reading: pin.reading)
            }
            return nil  // 覆蓋刪除點的 pin：拆掉
        }
        elements.remove(at: index)
        cursor -= 1
        rewalk()
    }

    private func rewalk() {
        walked = decoder.walk(elements, pins: pins)
    }

    private func reset() {
        elements = []
        cursor = 0
        pins = []
        walked = []
        composer.clear()
        sheet = nil
    }

    private func flushOutput() -> Output {
        guard let text = flush() else { return .ignored }
        return Output(handled: true, commitText: text)
    }

    private func committedText() -> String {
        elementTexts().joined() + composer.display
    }

    /// 每個元素對應的顯示文字：詞值一字對一音時逐字分配，否則整段掛在首元素
    private func elementTexts() -> [String] {
        var texts = [String](repeating: "", count: elements.count)
        for segment in walked {
            let chars = Array(segment.value)
            if chars.count == segment.length {
                for (offset, ch) in chars.enumerated() {
                    texts[segment.start + offset] = String(ch)
                }
            } else if segment.start < texts.count {
                texts[segment.start] = segment.value
            }
        }
        return texts
    }

    /// 游標所在的詞段（按 ↓ 開候選的對象）
    private func anchorSegment() -> DecodedSegment? {
        guard !elements.isEmpty else { return nil }
        let index = min(cursor, elements.count - 1)
        return walked.first { $0.start <= index && index < $0.end }
    }
}
