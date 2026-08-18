import Testing
@testable import BlendKeyCore

let 測試詞庫 = Lexicon(dataText: """
# format org.openvanilla.mcbopomofo.sorted
ㄋㄧˇ 你 -4.0
ㄋㄧˇ 妳 -6.0
ㄋㄧˇ 擬 -7.0
ㄏㄠˇ 好 -4.5
ㄋㄧˇ-ㄏㄠˇ 你好 -6.0
ㄕˋ 是 -4.0
ㄕˋ-ㄐㄧㄝˋ 世界 -5.0
ㄐㄧㄝˋ 界 -7.0
ㄍㄠ 高 -5.5
ㄅㄚ 八 -5.0
ㄉㄚˇ 打 -5.0
""")

@Test func 詞庫載入與排序() {
    #expect(測試詞庫.maxSpan == 2)
    #expect(測試詞庫.unigrams("ㄋㄧˇ").map(\.value) == ["你", "妳", "擬"])
    #expect(測試詞庫.unigrams("不存在").isEmpty)
}

@Test func 整句組句偏好長詞() {
    let decoder = SentenceDecoder(lexicon: 測試詞庫)
    let result = decoder.walk([.reading("ㄋㄧˇ"), .reading("ㄏㄠˇ")])
    #expect(result.map(\.value) == ["你好"])  // -6.0 勝過 你+好（-8.5）
}

@Test func pin_強制改字後重走() {
    let decoder = SentenceDecoder(lexicon: 測試詞庫)
    let pin = DecodedSegment(start: 0, length: 1, value: "妳", reading: "ㄋㄧˇ")
    let result = decoder.walk([.reading("ㄋㄧˇ"), .reading("ㄏㄠˇ")], pins: [pin])
    #expect(result.map(\.value) == ["妳", "好"])  // pin 拆散了「你好」
}

@Test func 未知讀音以注音原樣通行() {
    let decoder = SentenceDecoder(lexicon: 測試詞庫)
    let result = decoder.walk([.reading("ㄨㄤˋ"), .reading("ㄕˋ")])
    #expect(result.map(\.value) == ["ㄨㄤˋ", "是"])
}

@Test func 直出片段原樣走過() {
    let decoder = SentenceDecoder(lexicon: 測試詞庫)
    let result = decoder.walk([.reading("ㄕˋ"), .literal("O"), .literal("K")])
    #expect(result.map(\.value) == ["是", "O", "K"])
}

@Test func 候選長詞在前() {
    let decoder = SentenceDecoder(lexicon: 測試詞庫)
    let segments = decoder.candidateSegments([.reading("ㄋㄧˇ"), .reading("ㄏㄠˇ")], start: 0)
    #expect(segments.first?.value == "你好")
    #expect(segments.map(\.value).contains("妳"))
}
