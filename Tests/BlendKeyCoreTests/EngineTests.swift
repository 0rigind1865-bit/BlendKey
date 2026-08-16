import Testing
@testable import BlendKeyCore

private func makeEngine() -> InputEngine {
    InputEngine(lexicon: 測試詞庫)
}

private func type(_ engine: InputEngine, _ keys: String) {
    for key in keys {
        _ = engine.handle(key == " " ? .space : .character(key))
    }
}

@Test func 連打自動組句() {
    let engine = makeEngine()
    type(engine, "su3cl3")  // ㄋㄧˇ ㄏㄠˇ
    #expect(engine.preedit().text == "你好")
}

@Test func Enter_上屏並清空() {
    let engine = makeEngine()
    type(engine, "su3cl3")
    let output = engine.handle(.enter)
    #expect(output.commitText == "你好")
    #expect(engine.preedit().isEmpty)
    #expect(engine.isIdle)
}

@Test func 空白鍵開候選窗並以數字選字() {
    let engine = makeEngine()
    type(engine, "su3cl3")
    _ = engine.handle(.space)
    let sheet = engine.sheetView()
    #expect(sheet != nil)
    #expect(sheet?.items.first?.value == "你好")  // 長詞在前，且目前走法預選
    // 候選順序：你好、你、妳、擬 → 選第 3 個「妳」
    _ = engine.handle(.character("3"))
    #expect(engine.sheetView() == nil)
    #expect(engine.preedit().text == "妳好")
}

@Test func 候選窗直式導航() {
    let engine = makeEngine()
    type(engine, "su3cl3 ")  // 開候選：你好、你、妳、擬
    _ = engine.handle(.arrowDown)  // ↓ → 你
    _ = engine.handle(.arrowDown)  // ↓ → 妳
    #expect(engine.sheetView()?.highlightedInPage == 2)
    _ = engine.handle(.arrowUp)    // ↑ → 你
    _ = engine.handle(.arrowDown)  // ↓ → 妳
    _ = engine.handle(.enter)      // 選「妳」
    #expect(engine.preedit().text == "妳好")
}

@Test func 游標回改字() {
    let engine = makeEngine()
    type(engine, "su3cl3")
    _ = engine.handle(.arrowLeft)   // 游標移到 你|好
    _ = engine.handle(.arrowDown)   // 開「你」所在詞段的候選
    let sheet = engine.sheetView()
    #expect(sheet != nil)
    _ = engine.handle(.character("3"))  // 妳
    #expect(engine.preedit().text == "妳好")
    let output = engine.handle(.enter)
    #expect(output.commitText == "妳好")
}

@Test func 退格刪音節與組字中退格() {
    let engine = makeEngine()
    type(engine, "su3cl")  // 你 + 組字中 ㄏㄠ
    #expect(engine.preedit().text == "你ㄏㄠ")
    _ = engine.handle(.backspace)  // 退掉 ㄠ
    #expect(engine.preedit().text == "你ㄏ")
    _ = engine.handle(.backspace)  // 退掉 ㄏ
    _ = engine.handle(.backspace)  // 退掉 你
    #expect(engine.isIdle)
}

@Test func 打錯鍵先上屏再放行() {
    let engine = makeEngine()
    type(engine, "su3")
    let output = engine.handle(.character("="))
    #expect(output.handled == false)
    #expect(output.commitText == "你")
    #expect(engine.isIdle)
}

@Test func 空引擎一切放行() {
    let engine = makeEngine()
    #expect(engine.handle(.space) == .ignored)
    #expect(engine.handle(.enter) == .ignored)
    #expect(engine.handle(.backspace) == .ignored)
    #expect(engine.handle(.arrowLeft) == .ignored)
}

@Test func 直出英文與注音混排() {
    let engine = makeEngine()
    type(engine, "su3")
    _ = engine.handle(.englishLiteral("O"))
    _ = engine.handle(.englishLiteral("K"))
    engine.endLiteralRun()  // Shift 單擊結束英文接續段
    type(engine, "cl3")
    #expect(engine.preedit().text == "你OK好")
    #expect(engine.handle(.enter).commitText == "你OK好")
}
