import Testing
@testable import BlendKeyCore

private func compose(_ keys: String) -> [Syllable] {
    var composer = SyllableComposer()
    var result: [Syllable] = []
    for key in keys {
        if case .composed(let syllable) = composer.press(key) {
            result.append(syllable)
        }
    }
    return result
}

@Test func 基本音節組成() {
    #expect(compose("su3").map(\.canonical) == ["ㄋㄧˇ"])   // s=ㄋ u=ㄧ 3=ˇ
    #expect(compose("cl3").map(\.canonical) == ["ㄏㄠˇ"])   // c=ㄏ l=ㄠ 3=ˇ
    #expect(compose("5j4").map(\.canonical) == ["ㄓㄨˋ"])   // 5=ㄓ j=ㄨ 4=ˋ
    #expect(compose("y jp ").map(\.canonical) == ["ㄗ", "ㄨㄣ"])  // 一聲＝空白、不標調
}

@Test func 輕聲與鍵序對照() {
    // 小麥 BPMFBase：吧 ㄅㄚ˙ 鍵序 187
    #expect(compose("187").map(\.canonical) == ["ㄅㄚ˙"])
}

@Test func 同槽覆寫() {
    // 連按兩個聲母，後者蓋前者
    #expect(compose("12j4").map(\.canonical) == ["ㄉㄨˋ"])
}

@Test func 調號打在空音節上被拒絕() {
    var composer = SyllableComposer()
    #expect(composer.press("3") == .rejected)
    #expect(composer.press("4") == .rejected)
}

@Test func 退格依按鍵順序回退() {
    var composer = SyllableComposer()
    _ = composer.press("s")  // ㄋ
    _ = composer.press("u")  // ㄧ
    #expect(composer.display == "ㄋㄧ")
    let first = composer.backspace()
    #expect(first)
    #expect(composer.display == "ㄋ")
    let second = composer.backspace()
    #expect(second)
    #expect(composer.isEmpty)
    let third = composer.backspace()
    #expect(!third)
}

@Test func 原始按鍵完整保留() {
    var composer = SyllableComposer()
    for key in "google" { _ = composer.press(key) }
    #expect(composer.rawKeys == "google")  // 供英文自動偵測
}
