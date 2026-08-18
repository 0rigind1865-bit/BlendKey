import Testing
@testable import BlendKeyCore

// MARK: - 全形標點

@Test func 閒置時標點直接上屏() {
    let engine = InputEngine(lexicon: 測試詞庫)
    let output = engine.handle(.character("<"))
    #expect(output == InputEngine.Output(handled: true, commitText: "，"))
    #expect(engine.isIdle)
}

@Test func 組字中標點進組字區() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "su3cl3" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.character("!"))
    #expect(engine.preedit().text == "你好！")
    #expect(engine.handle(.enter).commitText == "你好！")
}

@Test func 關閉全形標點時放行() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.fullWidthPunctuation = false
    #expect(engine.handle(.character("<")) == .ignored)
}

// MARK: - 英文自動偵測

private let 偵測器 = EnglishDetector(words: ["google", "hello", "OK"])

@Test func 英文詞偵測() {
    #expect(偵測器.isWord("google"))
    #expect(偵測器.isWord("Hello"))  // 不分大小寫
    #expect(偵測器.isWord("ok"))
    #expect(!偵測器.isWord("goog"))
    #expect(!偵測器.isWord("xyzzy"))
}

@Test func 打英文單字出現提示_Tab上字() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "google" { _ = engine.handle(.character(key)) }
    #expect(engine.englishHint == "google")
    #expect(engine.englishHintView()?.items.first?.value == "google")
    _ = engine.handle(.tab)
    #expect(engine.preedit().text == "google")
    #expect(engine.handle(.enter).commitText == "google")
}

@Test func 注音打字不誤觸英文提示() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "su3cl" { _ = engine.handle(.character(key)) }  // 你＋組字中 ㄏㄠ
    #expect(engine.englishHint == nil)  // rawKeys「cl」不是英文詞
}

@Test func 覆寫啟發式偵測詞典外的英文() {
    // 「vercel」不在詞典裡，但打字過程注音槽位反覆覆寫 → 仍給提示
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "vercel" { _ = engine.handle(.character(key)) }
    #expect(engine.englishHint == "vercel")
    _ = engine.handle(.tab)
    #expect(engine.handle(.enter).commitText == "vercel")
}

@Test func 單次覆寫的打錯字不誤觸() {
    let engine = InputEngine(lexicon: 測試詞庫)
    var composer = SyllableComposer()
    _ = composer.press("g")  // ㄕ
    _ = composer.press("s")  // 改成 ㄋ（覆寫一次）
    #expect(composer.overwriteCount == 1)
    _ = engine  // 引擎層由 rawKeys>=4 && 覆寫>=2 把關
}

// MARK: - 反向偵測（英文模式打注音）

private func makeChineseDetector() -> ChineseTypingDetector {
    let 已知讀音: Set<String> = ["ㄋㄧˇ", "ㄏㄠˇ", "ㄍㄠ", "ㄎㄠˇ"]
    return ChineseTypingDetector { 已知讀音.contains($0) }
}

private func feedAll(_ detector: inout ChineseTypingDetector, _ keys: String) -> String? {
    var fired: String?
    for key in keys where fired == nil {
        fired = detector.feed(key)
    }
    return fired
}

@Test func 英文模式打注音兩音節即切回並回報按鍵串() {
    var detector = makeChineseDetector()
    // ㄋㄧˇ ㄏㄠˇ：零覆寫＋數字聲調；回報整串按鍵供收回重組
    #expect(feedAll(&detector, "su3cl3") == "su3cl3")
}

@Test func 英文句子不誤觸() {
    var detector = makeChineseDetector()
    // hello world：注音槽位大量覆寫，永遠組不出乾淨音節
    #expect(feedAll(&detector, "hello world this is a test ") == nil)
}

@Test func 大寫燈誤觸時的真實案例會被抓到() {
    // 使用者回報：大寫燈亮著打注音，跑出「WJ OBJ/4」
    // W=ㄊ J=ㄨ 空白=一聲　O=ㄟ B=ㄖ J=ㄨ /=ㄥ 4=ˋ（中間有槽位覆寫）
    var detector = ChineseTypingDetector { ["ㄊㄨ", "ㄖㄨㄥˋ"].contains($0) }
    #expect(feedAll(&detector, "wj obj/4") != nil)
}

@Test func 打字中改鍵不影響偵測() {
    var detector = makeChineseDetector()
    // ㄋㄧˇ 打成 ㄇㄧˇ 再改回來（聲母覆寫），仍應判定為注音
    #expect(feedAll(&detector, "asu3cl3") != nil)
}

@Test func 英文語料不誤觸() {
    let sentences = [
        "hello world this is a test ", "please send me the file tomorrow ",
        "the quick brown fox jumps over the lazy dog ",
        "let me know if you need anything else ",
        "version 3 of the config file is ready ",   // 含數字
        "meeting at 4 pm in room 302 ",             // 含數字
        "git commit and push to main branch ",
        "npm install then run build ",
    ]
    for sentence in sentences {
        var detector = makeChineseDetector()
        #expect(feedAll(&detector, sentence) == nil, "英文誤判：\(sentence)")
    }
}

@Test func 零覆寫短英文因無數字聲調不誤觸() {
    var detector = makeChineseDetector()
    // "e " → ㄍ+一聲＝ㄍ（不在詞庫）；"el "→ㄍㄠ 在詞庫但無數字聲調，單次也不夠
    #expect(feedAll(&detector, "e el go no ") == nil)
}

@Test func 被打斷就重新計數() {
    var detector = makeChineseDetector()
    _ = feedAll(&detector, "su3")   // 一個合法音節
    detector.reset()                 // 使用者按了方向鍵
    #expect(feedAll(&detector, "cl3") == nil)  // 只剩一個音節，不觸發
}

@Test func 雜訊後的按鍵串只含乾淨音節() {
    var detector = makeChineseDetector()
    // 「xy 」是雜訊（有覆寫、組不出已知讀音），觸發時只回報後面乾淨的兩個音節
    #expect(feedAll(&detector, "xy su3cl3") == "su3cl3")
}

// MARK: - 長按直出

@Test func 長按字母直出英文() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.character("g"))          // 吃成 ㄕ
    _ = engine.handle(.repeatedCharacter("g"))  // 長按：退掉 ㄕ、改直出 g（開接續段）
    #expect(engine.preedit().text == "g")
    _ = engine.handle(.repeatedCharacter("g"))  // 後續重複吞掉，不會 ggg
    #expect(engine.preedit().text == "g")
    engine.endLiteralRun()                      // Shift 單擊結束接續段
    for key in "su3" { _ = engine.handle(.character(key)) }
    #expect(engine.handle(.enter).commitText == "g你")
}

@Test func 長按數字直出數字() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.character("8"))          // 吃成 ㄚ
    _ = engine.handle(.repeatedCharacter("8"))
    #expect(engine.preedit().text == "8")
}

@Test func 長按聲調鍵不誤觸() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "su3" { _ = engine.handle(.character(key)) }  // 你（音節已完成）
    let output = engine.handle(.repeatedCharacter("3"))
    #expect(output == .consumed)
    #expect(engine.preedit().text == "你")
}

@Test func 閒置時長按未映射鍵放行() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.fullWidthPunctuation = false
    #expect(engine.handle(.repeatedCharacter("=")) == .ignored)
}

// MARK: - Shift 單擊偵測

private func run(_ detector: inout ShiftTapDetector, _ events: [(ShiftTapDetector.FlagsEvent, Double)]) -> Bool {
    var fired = false
    for (event, time) in events {
        fired = detector.process(event, at: time)
    }
    return fired
}

@Test func Shift單擊觸發() {
    var detector = ShiftTapDetector()
    #expect(run(&detector, [(.shiftDown(keyCode: 56), 0), (.allReleased(keyCode: 56), 0.1)]))
}

@Test func Shift長按不觸發() {
    var detector = ShiftTapDetector()
    #expect(!run(&detector, [(.shiftDown(keyCode: 56), 0), (.allReleased(keyCode: 56), 0.5)]))
}

@Test func Shift加字母不觸發() {
    var detector = ShiftTapDetector()
    _ = detector.process(.shiftDown(keyCode: 56), at: 0)
    detector.noteKeyDown()  // Shift+G 打字
    let fired = detector.process(.allReleased(keyCode: 56), at: 0.1)
    #expect(!fired)
}

@Test func 組合修飾鍵不觸發() {
    var detector = ShiftTapDetector()
    #expect(!run(&detector, [
        (.shiftDown(keyCode: 56), 0),
        (.other, 0.05),  // cmd 加入
        (.allReleased(keyCode: 56), 0.1),
    ]))
}

@Test func 冗餘事件防抖() {
    var detector = ShiftTapDetector()
    #expect(run(&detector, [(.shiftDown(keyCode: 56), 0), (.allReleased(keyCode: 56), 0.1)]))
    // Electron 式冗餘重放：40ms 內同樣序列
    #expect(!run(&detector, [(.shiftDown(keyCode: 56), 0.11), (.allReleased(keyCode: 56), 0.13)]))
}

@Test func 左右Shift不混淆() {
    var detector = ShiftTapDetector()
    #expect(!run(&detector, [(.shiftDown(keyCode: 56), 0), (.allReleased(keyCode: 60), 0.1)]))
}

// MARK: - 中英並列選字

@Test func 空白開中英並列選字_數字直選大小寫() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "google" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.space)  // 不組一聲字，改開並列選字
    #expect(engine.sheetView()?.items.map(\.value) == ["google", "Google", "GOOGLE", "高"])
    _ = engine.handle(.character("2"))
    #expect(engine.preedit().text == "Google")
    #expect(engine.handle(.enter).commitText == "Google")
}

@Test func 並列選字也能選一聲中文字() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "google" { _ = engine.handle(.character(key)) }  // 組字中恰為 ㄍㄠ
    _ = engine.handle(.space)
    _ = engine.handle(.character("4"))  // 最後一項＝一聲字「高」
    #expect(engine.preedit().text == "高")
}

@Test func 並列選字Esc關窗保留注音續打() {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.englishDetector = 偵測器
    for key in "google" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.space)
    _ = engine.handle(.escape)
    #expect(engine.sheetView() == nil)          // 窗已關
    #expect(engine.englishHint == "google")     // 注音與提示都還在
}

// MARK: - 英文接續段（大小寫混排）

@Test func Shift字母開段_小寫接續_混合大小寫() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.englishLiteral("G"))          // Shift+G 開段
    for key in "oogle" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "Google")
    engine.endLiteralRun()                            // Shift 單擊結束
    for key in "su3" { _ = engine.handle(.character(key)) }
    #expect(engine.handle(.enter).commitText == "Google你")
}

@Test func 接續段中空白與標點原樣半形() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.englishLiteral("T"))
    for key in "est.com v2" { _ = engine.handle(key == " " ? .space : .character(key)) }
    #expect(engine.preedit().text == "Test.com v2")  // 點與空白都是半形原樣
}

@Test func 長按字母也開接續段() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.character("g"))
    _ = engine.handle(.repeatedCharacter("g"))       // 長按 → literal g、開段
    for key in "oogle" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "google")
}

@Test func Esc結束接續段後注音恢復() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.englishLiteral("A"))
    _ = engine.handle(.escape)                        // 結束段（字母保留）
    for key in "su3" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "A你")
}

@Test func 退光接續段字母自動回注音() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.englishLiteral("G"))
    _ = engine.handle(.backspace)                     // 唯一的字母退掉
    #expect(engine.isInLiteralRun == false)
    for key in "su3" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "你")
}

// MARK: - 數字直出

@Test func 打小數Tab直出() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "1.62" { _ = engine.handle(.character(key)) }  // ㄅㄡˊ＋ㄉ
    #expect(engine.numberHint == "1.62")
    _ = engine.handle(.tab)
    #expect(engine.preedit().text == "1.62")
    #expect(engine.handle(.enter).commitText == "1.62")
}

@Test func 打數字直接Enter也對() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "162" { _ = engine.handle(.character(key)) }
    #expect(engine.handle(.enter).commitText == "162")
}

@Test func 中文後接數字() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "su3" { _ = engine.handle(.character(key)) }  // 你
    for key in "1.5" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.tab)
    #expect(engine.handle(.enter).commitText == "你1.5")
}

@Test func 打八不受數字追蹤影響() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "18 " { _ = engine.handle(.character(key)) }  // ㄅㄚ＋一聲
    #expect(engine.preedit().text == "八")
    #expect(engine.handle(.enter).commitText == "八")
}

@Test func 退格取消數字追蹤() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "1.6" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.backspace)
    #expect(engine.numberHint == nil)
}

@Test func 字母鍵取消數字追蹤() {
    let engine = InputEngine(lexicon: 測試詞庫)
    for key in "1k" { _ = engine.handle(.character(key)) }  // 1=ㄅ k=ㄜ：像在打注音
    #expect(engine.numberHint == nil)
}
