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

private func feedAll(_ detector: inout ChineseTypingDetector, _ keys: String) -> Bool {
    var fired = false
    for key in keys where !fired {
        fired = detector.feed(key)
    }
    return fired
}

@Test func 英文模式打注音兩音節即切回() {
    var detector = makeChineseDetector()
    #expect(feedAll(&detector, "su3cl3"))  // ㄋㄧˇ ㄏㄠˇ：零覆寫＋數字聲調
}

@Test func 英文句子不誤觸() {
    var detector = makeChineseDetector()
    // hello world：注音槽位大量覆寫，永遠組不出乾淨音節
    #expect(!feedAll(&detector, "hello world this is a test "))
}

@Test func 零覆寫短英文因無數字聲調不誤觸() {
    var detector = makeChineseDetector()
    // "e " → ㄍ+一聲＝ㄍ（不在詞庫）；"el "→ㄍㄠ 在詞庫但無數字聲調，單次也不夠
    #expect(!feedAll(&detector, "e el go no "))
}

@Test func 被打斷就重新計數() {
    var detector = makeChineseDetector()
    _ = feedAll(&detector, "su3")   // 一個合法音節
    detector.reset()                 // 使用者按了方向鍵
    #expect(!feedAll(&detector, "cl3"))  // 只剩一個音節，不觸發
}

// MARK: - 長按直出

@Test func 長按字母直出英文() {
    let engine = InputEngine(lexicon: 測試詞庫)
    _ = engine.handle(.character("g"))          // 吃成 ㄕ
    _ = engine.handle(.repeatedCharacter("g"))  // 長按：退掉 ㄕ、改直出 g
    #expect(engine.preedit().text == "g")
    _ = engine.handle(.repeatedCharacter("g"))  // 後續重複吞掉，不會 ggg
    #expect(engine.preedit().text == "g")
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
