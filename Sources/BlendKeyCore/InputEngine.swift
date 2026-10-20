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
            case caret      // 插入位置記號（見 InputEngine.caretMark）
        }
        public struct Piece: Equatable, Sendable {
            public let text: String
            public let style: Style
        }
        public let pieces: [Piece]
        public let caretUTF16: Int
        /// 游標所在詞的範圍（UTF-16 起點與長度）：組字中沒有注音時用它反白，
        /// 讓使用者看得見自己停在哪個詞。核心層零 Foundation 依賴，故不用 NSRange。
        public let activeRangeUTF16: (start: Int, length: Int)?

        public static func == (lhs: Preedit, rhs: Preedit) -> Bool {
            lhs.pieces == rhs.pieces && lhs.caretUTF16 == rhs.caretUTF16
                && lhs.activeRangeUTF16?.start == rhs.activeRangeUTF16?.start
                && lhs.activeRangeUTF16?.length == rhs.activeRangeUTF16?.length
        }

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
        /// 橫排（聯想詞）：像手機鍵盤的建議列
        public var horizontal = false
    }

    // MARK: - 狀態

    private let lexicon: Lexicon
    private var decoder: SentenceDecoder
    /// 候選字窗每頁字數（偏好設定）
    public var pageSize = 9

    private var elements: [Element] = []
    private var cursor = 0  // 元素邊界位置 0...elements.count
    private var pins: [DecodedSegment] = []
    private var composer = SyllableComposer()
    private var walked: [DecodedSegment] = []

    private struct Sheet {
        /// 選字改詞（pin）、插入符號、或把某個數字元素換成另一種寫法
        enum Kind: Equatable { case words, symbols, number(index: Int) }
        var all: [DecodedSegment]
        var anchor: Int
        var highlighted: Int
        var kind = Kind.words
    }
    private var sheet: Sheet?
    /// 已由長按轉成直出的鍵：吞掉它後續的自動重複
    private var longPressKey: Character?
    /// 進行中的「數字起頭英數串」（1.62、1mm、0.4mm；空字串＝未追蹤）與期間組出的元素數
    private var numericRaw = ""
    private var numericElements = 0
    /// 英文接續段：Shift+字母或長按開啟後，後續按鍵原樣直出（大小寫、數字、
    /// 半形標點、空白），直到 Shift 單擊／Esc／方向鍵／上屏結束
    public private(set) var isInLiteralRun = false
    /// 英文段裡的反向偵測（同英文模式）：發現在打注音就自動結束英文段、改組中文
    private lazy var literalRunDetector = ChineseTypingDetector { [lexicon] reading in
        !lexicon.unigrams(reading).isEmpty
    }

    /// 中英並列選字：組字中偵測到英文時按空白／↓ 開啟，
    /// 英文大小寫變體與一聲中文字並列，數字直選
    private enum BilingualChoice: Equatable {
        case english(String)
        case tone1(display: String)
    }
    private struct BilingualSheet {
        var choices: [BilingualChoice]
        var highlighted = 0
    }
    private var bilingual: BilingualSheet?

    /// 聯想詞（像手機鍵盤）：組字中依「你打過的詞語接續」提示下一個詞。
    /// 先按 Tab 進入選擇（第一個反白），再按 1〜5 選、或再按一次 Tab 選反白的；滑鼠點任一個。
    /// 組字中的 Tab 原本就不送給 app（沒有別的用途），
    /// 而且跟英文／數字提示同一個規則「Tab＝接受小窗的提示」，所以不和任何快捷鍵衝突。
    /// 不另設「接受並送出」鍵：Enter 的組合鍵各 app 都有用途（Shift+Enter 是聊天軟體換行），
    /// 打完字習慣按它的人會被多塞一個詞。要送出就 Tab 再 Enter。
    /// ponytail: 上屏後不提示——那時 Tab 屬於 app（縮排、換欄），只剩滑鼠能選反而礙眼
    public var associationsEnabled = true
    /// 按過 Tab、等使用者選第幾個；任何其他按鍵或組字區變動都會取消
    private var associationArmed = false

    /// AI 補句：殼層非同步問 AI 後填入，顯示在提示列最前面，按 → 接受。
    /// 組字區一有變動（rewalk）就作廢，所以不會顯示過期的補句。
    public var aiCompletion: String?

    /// 全形標點開關（偏好設定）
    public var fullWidthPunctuation = true
    /// 中英之間自動加空白開關（偏好設定）：我愛mac → 我愛 mac
    public var autoSpacing = true
    /// 相似音修正開關（偏好設定）：ㄓㄗ、ㄔㄘ、ㄕㄙ、ㄌㄋ、ㄈㄏ、ㄣㄥ、ㄢㄤ 互通
    public var fuzzyReadingEnabled = false {
        didSet {
            decoder.fuzzyEnabled = fuzzyReadingEnabled
            rewalk()
        }
    }
    /// 英文自動偵測開關（偏好設定）
    public var englishHintEnabled = true
    /// 英文詞偵測器（載妥後注入；nil 時只剩覆寫啟發式）
    public var englishDetector: EnglishDetector?
    /// 使用者選字學習與自造詞（nil 時不學習）
    public var userPhrases: UserPhraseStore? {
        didSet {
            if let store = userPhrases {
                decoder.scoreBonus = { [weak store] reading, value in
                    store?.bonus(reading: reading, value: value) ?? 0
                }
                decoder.extraUnigrams = { [weak store] reading in
                    store?.userWords(reading: reading) ?? []
                }
                decoder.transitionBonus = { [weak store] previous, next in
                    store?.transitionBonus(from: previous, to: next) ?? 0
                }
            } else {
                decoder.scoreBonus = nil
                decoder.extraUnigrams = nil
                decoder.transitionBonus = nil
            }
            rewalk()
        }
    }

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
        decoder = SentenceDecoder(lexicon: lexicon)
    }

    /// 空組字區的符號表、聯想詞提示也算忙（Cmd 快捷鍵才會先收起）
    public var isIdle: Bool { elements.isEmpty && composer.isEmpty && sheet == nil }

    /// 插入位置記號：組字中的游標不在句尾時顯示，讓使用者看得見會插在哪兩個字中間。
    /// macOS 不保證 app 會在組字文字裡畫游標，所以自己畫一個（純顯示，不會被送出）。
    public static let caretMark = "‸"

    /// 數字（1.62）或「數字＋單位」（1mm、0.4mm、5V）——Tab 直接輸出原樣。
    /// 後面接的字母必須是已知單位才算，否則多半是在打注音
    /// （2k＝ㄉㄜ的、2l＝ㄉㄠ到、1i＝ㄅㄛ波 都是常用字，不能亂跳提示）。
    public var numberHint: String? {
        guard numericRaw.contains(where: \.isNumber) else { return nil }
        guard let firstLetter = numericRaw.firstIndex(where: \.isLetter) else {
            return numericRaw  // 純數字與 . , -
        }
        let unit = String(numericRaw[firstLetter]).lowercased()
            + String(numericRaw[numericRaw.index(after: firstLetter)...]).lowercased()
        return Self.units.contains(unit) ? numericRaw : nil
    }

    /// 常見單位白名單。刻意排除 k／l／p／i／o／u／j 等單字母——
    /// 它們接在數字鍵後面正好是 ㄉㄜ、ㄉㄠ、ㄅㄛ 這些高頻注音組合。
    private static let units: Set<String> = [
        // 長度
        "mm", "cm", "dm", "m", "km", "nm", "um", "in", "ft", "yd", "mil",
        // 重量
        "g", "kg", "mg", "t", "lb", "oz",
        // 容量
        "ml", "cc", "gal",
        // 時間與頻率
        "s", "ms", "ns", "us", "min", "h", "hr", "hz", "khz", "mhz", "ghz", "rpm", "bpm", "fps",
        // 電
        "v", "mv", "kv", "a", "ma", "w", "kw", "mw", "wh", "kwh", "ah", "mah", "ohm",
        // 資料
        "b", "kb", "mb", "gb", "tb", "bit", "bps", "mbps", "gbps",
        // 溫度、角度、壓力
        "c", "f", "deg", "rad", "bar", "psi", "pa", "kpa", "mpa",
        // 顯示與倍率
        "px", "pt", "dpi", "ppi", "x", "n",
    ]

    /// 組字中的原始按鍵看起來是英文時，提供 Tab 直接上英文的提示。
    /// 兩個訊號：命中英文詞典，或注音槽位被反覆覆寫（打英文的特徵）。
    public var englishHint: String? {
        guard englishHintEnabled else { return nil }
        let raw = composer.rawKeys
        // 允許字母數字混合（1mm、3D、v2），但至少要有一個字母——純數字歸 numberHint
        guard raw.count >= 3, raw.allSatisfy({ $0.isLetter || $0.isNumber }),
              raw.contains(where: \.isLetter) else { return nil }
        if let detector = englishDetector, detector.isWord(raw) { return raw }
        // 注音槽位被覆寫＝打字途中改鍵，多半不是在打注音
        if composer.overwriteCount >= 1 { return raw }
        return nil
    }

    /// 組字中的顯示：偵測到英文就顯示原始字母——打 google 看到 google，
    /// 而不是被覆寫剩下的「ㄍㄠ」；Enter 送出的也是這個
    private var composingText: String { englishHint ?? composer.display }

    // MARK: - 事件入口

    public func handle(_ key: KeyInput) -> Output {
        if case .repeatedCharacter = key {} else { longPressKey = nil }
        switch key {
        case .character, .space: break
        default: literalRunDetector.reset()  // 只有連續打字才累積，其他鍵都打斷
        }
        switch key {
        case .character, .space, .tab, .enter: break  // 這些要用到數字追蹤；character/space 自行管理
        default: cancelNumericRun()
        }
        if associationArmed, let output = handleArmedAssociations(key) {
            return output
        }
        if bilingual != nil, let output = handleInBilingual(key) {
            return output
        }
        if sheet != nil, let output = handleInSheet(key) {
            return output
        }
        switch key {
        case .character(let ch):
            if isInLiteralRun { return handleLiteralRunKey(ch) }
            return handleCharacter(ch)
        case .repeatedCharacter(let ch):
            if isInLiteralRun {
                if longPressKey == ch { return .consumed }  // 長按轉換後的殘餘重複仍要吞
                insertLiteral(String(ch))  // 段中按住新鍵＝真的要連打（如 aaa）
                return .consumed
            }
            return handleLongPress(ch)
        case .englishLiteral(let ch):
            // 組字中的按鍵原樣併進英文段：iPhone 的 i、macOS 的 mac 不能被吃掉
            let pending = composer.rawKeys
            composer.clear()
            for key in pending { insertLiteral(String(key)) }
            insertLiteral(String(ch))
            isInLiteralRun = true  // 開始英文接續段：後續小寫字母原樣直出
            return .consumed
        case .space:
            if isInLiteralRun { return handleLiteralRunKey(" ") }
            if !composer.isEmpty {
                // 偵測到英文：空白改開中英並列選字，不硬組一聲字
                if englishHint != nil { openBilingualSheet(); return .consumed }
                // 數字串且標一聲也組不出字（ㄅ、ㄉ 單獨不是字）：空白＝直接出數字。
                // 組得出字的維持注音優先（18＋空白還是「八」，要 18 用 Tab）。
                if numberHint != nil, !tone1FormsKnownReading() {
                    acceptNumber()
                    return .consumed
                }
                return handleCharacter(" ")
            }
            // 組字區只有這串數字（沒有注音）：空白直接送出，不開候選窗
            if numberHint != nil, numericElements == elements.count, !elements.isEmpty {
                return Output(handled: true, commitText: flush())
            }
            if !elements.isEmpty { openSheet(); return .consumed }
            return .ignored
        case .enter:
            return flushOutput()
        case .escape:
            if isInLiteralRun { isInLiteralRun = false; return .consumed }
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
            // 接續段的字母全被退光就自動結束，回到注音組字
            if isInLiteralRun, cursor == 0 || !isLiteral(at: cursor - 1) {
                isInLiteralRun = false
            }
            return .consumed
        case .arrowLeft:
            isInLiteralRun = false
            guard !isIdle else { return .ignored }
            if composer.isEmpty { cursor = max(0, cursor - 1) }
            return .consumed
        case .arrowRight:
            // 游標在句尾時 → 原本沒有作用（Gmail 智慧撰寫也用 → 接受），拿來接受 AI 補句
            if let completion = visibleCompletion {
                acceptAssociation(completion)
                return .consumed
            }
            isInLiteralRun = false
            guard !isIdle else { return .ignored }
            if composer.isEmpty { cursor = min(elements.count, cursor + 1) }
            return .consumed
        case .arrowDown:
            isInLiteralRun = false
            if !composer.isEmpty {
                if englishHint != nil { openBilingualSheet() }  // 組字中只開中英並列
                return elements.isEmpty && englishHint == nil ? .ignored : .consumed
            }
            guard !elements.isEmpty else { return .ignored }
            openSheet()
            return .consumed
        case .tab:
            if !visibleAssociations.isEmpty {
                associationArmed = true
                return .consumed
            }
            if numberHint != nil {
                acceptNumber()
                return .consumed
            }
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
        learnPinnedWords()
        // 上屏的詞序列＝真實連續文本語料，記下詞對供下次斷詞參考
        if composer.isEmpty, walked.count >= 2 {
            userPhrases?.noteCommit(walked.map(\.value))
        }
        let text = committedText()
        reset()
        return text.isEmpty ? nil : text
    }

    /// 自動造詞：上屏時，把「連續被改字（pin）的單字串」回報為造詞候補。
    /// 連續兩次上屏同一串，就升格為使用者詞（UserPhraseStore 負責門檻）。
    private func learnPinnedWords() {
        guard let store = userPhrases else { return }
        var run: [DecodedSegment] = []
        func closeRun() {
            defer { run = [] }
            guard (2...6).contains(run.count) else { return }
            store.noteWordCandidate(
                reading: run.compactMap(\.reading).joined(separator: "-"),
                value: run.map(\.value).joined()
            )
        }
        for segment in walked {
            let isPinned = pins.contains {
                $0.start == segment.start && $0.length == segment.length && $0.value == segment.value
            }
            if segment.length == 1, segment.reading != nil, isPinned {
                run.append(segment)
            } else {
                closeRun()
            }
        }
        closeRun()
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

    // MARK: - 字元與候選窗

    /// 長按（自動重複）：把剛被吃成注音組件的鍵退掉、改為直出原始字元，
    /// 並開始英文接續段（長按開頭＝要打小寫英文）。
    /// 聲調鍵除外（按下當下音節已完成，undo 語意混亂，且空組字區時聲調鍵本來就放行）。
    private func handleLongPress(_ ch: Character) -> Output {
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
    private func handleLiteralRunKey(_ ch: Character) -> Output {
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
    private func trackNumeric(_ ch: Character, composerWasEmpty: Bool) {
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
    private func tone1FormsKnownReading() -> Bool {
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

    private func cancelNumericRun() {
        numericRaw = ""
        numericElements = 0
    }

    /// 把這串數字期間組出的注音全數退掉，改為直出數字文字
    private func acceptNumber() {
        guard let number = numberHint else { return }
        composer.clear()
        for _ in 0..<min(numericElements, cursor) {
            removeElement(at: cursor - 1)
        }
        insertLiteral(number)
        cancelNumericRun()
    }

    private func handleCharacter(_ ch: Character) -> Output {
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
            cancelNumericRun()
            if !composer.isEmpty { return .consumed }  // 打錯鍵不打斷組字
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

    /// 打完英文或數字沒按 Tab 就接著打注音：鍵全混進同一個音節（push＋上＝ㄕㄧㄤˋ、150＋個＝ㄍㄜˋ，
    /// 前面的鍵被後面的覆寫掉）。這時拆成「英文詞／數字＋剩下組出的音節」，前段越長越優先。
    /// 只在「整串查不到」或「中途有覆寫」時才試——正常打注音兩者都不會發生。
    /// ponytail: 一聲（空白收尾）且整串都是字母時會先被英文提示攔去開中英並列窗，那條路不拆
    private func splitLiteralPrefix(_ keys: String, composed: Syllable, overwritten: Bool) -> (String, Syllable)? {
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

    private func handleInSheet(_ key: KeyInput) -> Output? {
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
        case .englishLiteral:
            sheet = nil
            return nil
        case .repeatedCharacter:
            return .consumed  // 候選窗開啟時忽略長按重複，避免連續選字
        }
    }

    // MARK: - 聯想詞

/// 目前該顯示的聯想詞（空＝不顯示）。其他視窗或提示開著時讓路。
    /// 跟著最後一個詞即時更新；打注音打到一半也維持顯示，不會每個音節閃一下。
    private var visibleAssociations: [String] {
        guard associationsEnabled, suggestionsAllowed, let store = userPhrases, let last = walked.last
        else { return [] }
        return store.nextWords(after: last.value, limit: 5)
    }

    private var visibleCompletion: String? { suggestionsAllowed ? aiCompletion : nil }

    /// 提示列（聯想詞、AI 補句）可以出現的時機：其他視窗或提示開著時讓路，
    /// 游標回頭改字時不提示
    private var suggestionsAllowed: Bool {
        sheet == nil && bilingual == nil && !isInLiteralRun && englishHint == nil && numberHint == nil
            && cursor == elements.count && !elements.isEmpty
    }

    /// 要給 AI 接下去的「目前組好的字」：注音打完一個音節、游標在句尾時才有值
    public var completionContext: String? {
        guard composer.isEmpty, suggestionsAllowed else { return nil }
        return elementTexts().joined()
    }

    private func handleArmedAssociations(_ key: KeyInput) -> Output? {
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
    private func acceptAssociation(_ word: String) {
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

    // MARK: - 中英並列選字

    private func openBilingualSheet() {
        guard let raw = englishHint else { return }
        var choices: [BilingualChoice] = []
        var seen = Set<String>()
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

    private func handleInBilingual(_ key: KeyInput) -> Output? {
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

    private func selectBilingual(_ choice: BilingualChoice) {
        bilingual = nil
        switch choice {
        case .english(let text):
            composer.clear()
            insertLiteral(text)
        case .tone1:
            _ = handleCharacter(" ")  // 照原本的空白行為組一聲字
        }
    }

    private func openSheet() {
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
        var all = decoder.candidateSegments(elements, start: anchor.start)
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

    private func openSymbolSheet() {
        sheet = Sheet(
            all: SymbolTable.symbols.map { DecodedSegment(start: cursor, length: 0, value: $0, reading: nil) },
            anchor: cursor, highlighted: 0, kind: .symbols
        )
    }

    private func choose(_ segment: DecodedSegment, kind: Sheet.Kind) -> Output {
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

    private func select(_ segment: DecodedSegment) {
        pins.removeAll { $0.start < segment.end && segment.start < $0.end }
        pins.append(segment)
        if let reading = segment.reading, !DateMacro.forms(for: reading).contains(segment.value) {
            userPhrases?.bump(reading: reading, value: segment.value)
        }
        rewalk()
        cursor = min(segment.end + 1, elements.count)  // 指向下一個字（游標＝其右邊）
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
        aiCompletion = nil  // 組字區變了：舊的補句作廢
    }

    /// 結束英文接續段（Shift 單擊時由殼層呼叫）
    public func endLiteralRun() {
        isInLiteralRun = false
    }

    private func isLiteral(at index: Int) -> Bool {
        guard elements.indices.contains(index) else { return false }
        if case .literal = elements[index] { return true }
        return false
    }

    private func reset() {
        elements = []
        cursor = 0
        pins = []
        walked = []
        composer.clear()
        sheet = nil
        bilingual = nil
        associationArmed = false
        isInLiteralRun = false
        cancelNumericRun()
    }

    private func flushOutput() -> Output {
        // 這裡刻意不碰數字提示：「打」＝2ㄉ8ㄚ3ˇ 整串都是數字鍵，
        // Enter 若自動選數字就會把打好的中文換成 283。要數字請按 Tab。
        guard let text = flush() else { return .ignored }
        return Output(handled: true, commitText: text)
    }

    private func committedText() -> String {
        spaced(elementTexts() + [composingText]).joined()
    }

    /// 漢字與英數字相鄰處補一個空白（加在後一段開頭）。已有空白就不再加，重複套用結果不變。
    /// ponytail: 只看組字區內部；跟 app 裡已上屏的前文之間不補（要讀 client 前文才做得到）
    private func spaced(_ texts: [String]) -> [String] {
        guard autoSpacing else { return texts }
        func isHan(_ ch: Character) -> Bool { ch.unicodeScalars.first?.properties.isIdeographic == true }
        func isAlnum(_ ch: Character) -> Bool { ch.isASCII && (ch.isLetter || ch.isNumber) }
        var result = texts
        var previous: Character?
        for index in result.indices {
            guard let first = result[index].first else { continue }
            if let previous, (isHan(previous) && isAlnum(first)) || (isAlnum(previous) && isHan(first)) {
                result[index] = " " + result[index]
            }
            previous = result[index].last
        }
        return result
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
        return spaced(texts)
    }

    /// 游標所在的詞段（按 ↓ 開候選的對象）
    private func anchorSegment() -> DecodedSegment? {
        guard !elements.isEmpty else { return nil }
        let index = max(0, min(cursor - 1, elements.count - 1))
        return walked.first { $0.start <= index && index < $0.end }
    }
}
