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

    let lexicon: Lexicon
    var decoder: SentenceDecoder
    /// 候選字窗每頁字數（偏好設定）
    public var pageSize = 9 { didSet { pageSize = min(max(pageSize, 1), 9) } }  // 0 會讓換頁除以零

    var elements: [Element] = []
    var cursor = 0  // 元素邊界位置 0...elements.count
    var pins: [DecodedSegment] = []
    var composer = SyllableComposer()
    var walked: [DecodedSegment] = []

    struct Sheet {
        /// 選字改詞（pin）、插入符號、或把某個數字元素換成另一種寫法
        enum Kind: Equatable { case words, symbols, number(index: Int) }
        var all: [DecodedSegment]
        var anchor: Int
        var highlighted: Int
        var kind = Kind.words
    }
    var sheet: Sheet?
    /// 已由長按轉成直出的鍵：吞掉它後續的自動重複
    var longPressKey: Character?
    /// 進行中的「數字起頭英數串」（1.62、1mm、0.4mm；空字串＝未追蹤）與期間組出的元素數
    var numericRaw = ""
    var numericElements = 0
    /// 英文接續段：Shift+字母或長按開啟後，後續按鍵原樣直出（大小寫、數字、
    /// 半形標點、空白），直到 Shift 單擊／Esc／方向鍵／上屏結束
    public internal(set) var isInLiteralRun = false
    /// 英文段裡的反向偵測（同英文模式）：發現在打注音就自動結束英文段、改組中文
    lazy var literalRunDetector = ChineseTypingDetector { [lexicon] reading in
        !lexicon.unigrams(reading).isEmpty
    }

    /// 中英並列選字：組字中偵測到英文時按空白／↓ 開啟，
    /// 英文大小寫變體與一聲中文字並列，數字直選
    enum BilingualChoice: Equatable {
        case english(String)
        case tone1(display: String)
    }
    struct BilingualSheet {
        var choices: [BilingualChoice]
        var highlighted = 0
    }
    var bilingual: BilingualSheet?

    /// 聯想詞（像手機鍵盤）：組字中依「你打過的詞語接續」提示下一個詞。
    /// 先按 Tab 進入選擇（第一個反白），再按 1〜5 選、或再按一次 Tab 選反白的；滑鼠點任一個。
    /// 組字中的 Tab 原本就不送給 app（沒有別的用途），
    /// 而且跟英文／數字提示同一個規則「Tab＝接受小窗的提示」，所以不和任何快捷鍵衝突。
    /// 不另設「接受並送出」鍵：Enter 的組合鍵各 app 都有用途（Shift+Enter 是聊天軟體換行），
    /// 打完字習慣按它的人會被多塞一個詞。要送出就 Tab 再 Enter。
    /// ponytail: 上屏後不提示——那時 Tab 屬於 app（縮排、換欄），只剩滑鼠能選反而礙眼
    public var associationsEnabled = true
    /// 按過 Tab、等使用者選第幾個；任何其他按鍵或組字區變動都會取消
    var associationArmed = false

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
    /// 快捷文字本（殼層從檔案載入；空＝沒有）
    public var shortcuts = Shortcuts()
    /// 游標前已上屏的文字（控制器在組字開始前餵進來；CLI／測試可不設）。
    /// 只留結尾連續的漢字、最多 2 個，遇標點英數就停；只在記憶體、不寫檔
    public var leftContext = "" {
        didSet { decoder.leftContext = Self.contextKey(leftContext) }
    }

    public static func contextKey(_ text: String) -> String {
        var key: [Character] = []
        for ch in text.reversed() {
            guard ch.unicodeScalars.first?.properties.isIdeographic == true, key.count < 2 else { break }
            key.insert(ch, at: 0)
        }
        return String(key)
    }

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
                decoder.selectionBonus = { [weak store] previous, reading, value in
                    store?.selectionBonus(after: previous, reading: reading, value: value) ?? 0
                }
            } else {
                decoder.scoreBonus = nil
                decoder.extraUnigrams = nil
                decoder.transitionBonus = nil
                decoder.selectionBonus = nil
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
    static let units: Set<String> = [
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
        let raw = composer.rawKeys
        // 快捷文字本的縮寫：不管偵測開不開都認（使用者自己定義的）
        if raw.count >= 2, shortcuts.expansion(for: raw) != nil { return raw }
        guard englishHintEnabled else { return nil }
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
    var composingText: String { englishHint ?? composer.display }

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
            if numberHint != nil, !elements.isEmpty, elements.allSatisfy({ if case .literal = $0 { true } else { false } }) {
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
        case .shiftBackspace:
            // 「這個字選錯了」：忘掉游標左邊那個詞的學習（前文選字、全域選字、自造詞、詞對），拆掉 pin 重算
            guard composer.isEmpty, let segment = anchorSegment(), let reading = segment.reading else {
                return isIdle ? .ignored : .consumed
            }
            userPhrases?.forget(reading: reading, value: segment.value, after: previousWord(before: segment.start))
            pins.removeAll { $0.start < segment.end && segment.start < $0.end }
            rewalk()
            return .consumed
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
                return .consumed  // 組字區有字就不能把 ↓ 漏給 app
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
            acceptHint()
            // 組字區只有英文（前面沒中文）：送出並把 Tab 還給 app——
            // 終端機的自動補完、Claude Code 的 / 指令照常能用。前面有中文時 Tab 只收字，不送
            if isPureLiteral { return Output(handled: false, commitText: flush()) }
            return isIdle ? .ignored : .consumed
        case .arrowUp, .pageUp, .pageDown:
            return isIdle ? .ignored : .consumed
        }
    }

    /// 失焦／換行時把組字區內容送出
    public func flush() -> String? {
        learnPinnedWords()
        // 上屏的詞序列＝真實連續文本語料，記下詞對供下次斷詞參考。
        // 前文當第一個詞的前詞：分段送出（先「好」再「吧」）也學得到接續；
        // 2 字前文另記最後 1 字，查詢時退而求其次用得上
        if composer.isEmpty, !walked.isEmpty, let store = userPhrases {
            let words = walked.map(\.value)
            let context = decoder.leftContext
            store.noteCommit((context.isEmpty ? [] : [context]) + words)
            if context.count == 2 { store.noteCommit([String(context.suffix(1)), words[0]]) }
        }
        let text = committedText()
        reset()
        return text.isEmpty ? nil : text
    }

    /// 自動造詞：上屏時，把「連續被改字（pin）的單字串」回報為造詞候補。
    /// 升格門檻由 UserPhraseStore 決定（目前一次就學）。
    func learnPinnedWords() {
        guard let store = userPhrases else { return }
        var run: [DecodedSegment] = []
        var changed = false  // 這串裡至少有一個字是使用者真的改過的（不是只確認、也不是 AI 改的）
        func closeRun() {
            defer { run = []; changed = false }
            guard changed, (2...6).contains(run.count) else { return }
            store.noteWordCandidate(
                reading: run.compactMap(\.reading).joined(separator: "-"),
                value: run.map(\.value).joined()
            )
        }
        for segment in walked {
            let pin = pins.first {
                $0.start == segment.start && $0.length == segment.length && $0.value == segment.value
            }
            if segment.length == 1, segment.reading != nil, let pin {
                run.append(segment)
                if !pin.keepsOriginal { changed = true }
            } else {
                closeRun()
            }
        }
        closeRun()
    }

    // MARK: - 元素操作

    func insertReading(_ syllable: Syllable) {
        insert(.reading(syllable.canonical))
    }

    func insertLiteral(_ text: String) {
        insert(.literal(text))
    }

    func insert(_ element: Element) {
        pins = pins.compactMap { pin in
            if pin.end <= cursor { return pin }
            if pin.start >= cursor {
                return pin.shifted(by: 1)
            }
            return nil  // 插入點落在 pin 中間：拆掉
        }
        elements.insert(element, at: cursor)
        cursor += 1
        rewalk()
    }

    func removeElement(at index: Int) {
        pins = pins.compactMap { pin in
            if pin.end <= index { return pin }
            if pin.start > index {
                return pin.shifted(by: -1)
            }
            return nil  // 覆蓋刪除點的 pin：拆掉
        }
        elements.remove(at: index)
        cursor -= 1
        rewalk()
    }

    func rewalk() {
        walked = decoder.walk(elements, pins: pins)
        aiCompletion = nil  // 組字區變了：舊的補句作廢
    }

    /// 結束英文接續段（Shift 單擊時由殼層呼叫）
    public func endLiteralRun() {
        isInLiteralRun = false
    }

    func isLiteral(at index: Int) -> Bool {
        guard elements.indices.contains(index) else { return false }
        if case .literal = elements[index] { return true }
        return false
    }

    func reset() {
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

    func flushOutput() -> Output {
        // 數字鍵串組不成中文（1.62＝ㄅㄡˊ＋半個ㄉ）：Enter 直接出數字。
        // 組得成的維持中文——「打」＝2ㄉ8ㄚ3ˇ 整串都是數字鍵，不能變 283；要數字請按 Tab。
        if numberHint != nil, numericRunIsNotChinese { acceptNumber() }
        // 快捷文字本的縮寫：Enter 送出展開內容（要縮寫本身請按 Tab）
        if let raw = englishHint, shortcuts.expansion(for: raw) != nil { acceptHint(expandingShortcut: true) }
        guard let text = flush() else { return .ignored }
        return Output(handled: true, commitText: text)
    }

    /// 數字串期間組出的東西有沒有不成字的：半個音節，或詞庫查不到的讀音（顯示成注音符號）
    var numericRunIsNotChinese: Bool {
        if !composer.isEmpty { return true }
        let start = cursor - min(numericElements, cursor)
        return walked.contains { $0.start >= start && $0.end <= cursor && $0.reading != nil && $0.value == $0.reading }
    }

    func committedText() -> String {
        spaced(elementTexts() + [composingText]).joined()
    }

    /// 漢字與英數字相鄰處補一個空白（加在後一段開頭）。已有空白就不再加，重複套用結果不變。
    /// ponytail: 只看組字區內部；跟 app 裡已上屏的前文之間不補（要讀 client 前文才做得到）
    func spaced(_ texts: [String]) -> [String] {
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
    func elementTexts() -> [String] {
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
    func anchorSegment() -> DecodedSegment? {
        guard !elements.isEmpty else { return nil }
        let index = max(0, min(cursor - 1, elements.count - 1))
        return walked.first { $0.start <= index && index < $0.end }
    }
}
