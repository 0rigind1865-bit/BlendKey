import Testing
@testable import BlendKeyCore

private let 相似音詞庫 = Lexicon(dataText: """
ㄓㄨㄥ 中 -4.0
ㄗㄨㄥ 宗 -7.0
ㄧㄥ 應 -5.0
""")

@Test func 相似音變體_單音節() {
    let variants = FuzzyReading.variants(of: "ㄗㄨㄥ")
    #expect(Set(variants) == ["ㄓㄨㄥ", "ㄗㄨㄣ", "ㄓㄨㄣ"])  // ㄗ↔ㄓ、ㄥ↔ㄣ 兩個位置的組合
    #expect(FuzzyReading.variants(of: "ㄅㄚ").isEmpty)         // 沒有可混淆的音就沒有變體
}

@Test func 相似音變體_多音節與上限() {
    #expect(FuzzyReading.variants(of: "ㄓ-ㄕˋ").contains("ㄗ-ㄙˋ"))
    #expect(FuzzyReading.variants(of: "ㄓㄣ-ㄓㄣ-ㄓㄣ", limit: 5).count == 5)
}

@Test func 相似音關閉時不影響() {
    let decoder = SentenceDecoder(lexicon: 相似音詞庫)
    #expect(decoder.walk([.reading("ㄧㄣ")]).map(\.value) == ["ㄧㄣ"])  // 查不到就原樣通行
}

@Test func 相似音開啟後打錯也找得到_且正確讀音仍優先() {
    var decoder = SentenceDecoder(lexicon: 相似音詞庫)
    decoder.fuzzyEnabled = true
    #expect(decoder.walk([.reading("ㄧㄣ")]).map(\.value) == ["應"])
    // ㄗㄨㄥ 自己有「宗」(-7.0)，相似音「中」(-4.0-6.0=-10.0) 只能排後面
    let candidates = decoder.candidateSegments([.reading("ㄗㄨㄥ")], start: 0).map(\.value)
    #expect(candidates == ["宗", "中"])
}

@Test func 引擎開關相似音即時重組() {
    let engine = InputEngine(lexicon: 測試詞庫)  // 詞庫只有 ㄓ 知，沒有 ㄗ
    for key in "y " { _ = engine.handle(key == " " ? .space : .character(key)) }  // ㄗ 一聲
    #expect(engine.preedit().text == "ㄗ")
    engine.fuzzyReadingEnabled = true
    #expect(engine.preedit().text == "知")
    engine.fuzzyReadingEnabled = false
    #expect(engine.preedit().text == "ㄗ")
}
