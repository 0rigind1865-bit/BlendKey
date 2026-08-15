import Foundation
import Testing
@testable import BlendKeyCore

@Test func 選字被記住_下次自動偏向() {
    let store = UserPhraseStore(fileURL: nil)  // 純記憶體
    // 第一次：預設走「你」，使用者改選「妳」
    let first = InputEngine(lexicon: 測試詞庫)
    first.userPhrases = store
    for key in "su3" { _ = first.handle(.character(key)) }
    #expect(first.preedit().text == "你")
    _ = first.handle(.space)                 // 開候選
    _ = first.handle(.character("2"))        // 選「妳」（單音節：你、妳、擬）
    #expect(first.preedit().text == "妳")
    _ = first.handle(.enter)

    // 再選一次加重權重（2.0×ln(1+2) ≈ 2.2 > 你妳分差 2.0）
    let second = InputEngine(lexicon: 測試詞庫)
    second.userPhrases = store
    for key in "su3" { _ = second.handle(.character(key)) }
    _ = second.handle(.space)
    _ = second.handle(.character("2"))
    _ = second.handle(.enter)

    // 第三次：不用選，直接組出「妳」
    let third = InputEngine(lexicon: 測試詞庫)
    third.userPhrases = store
    for key in "su3" { _ = third.handle(.character(key)) }
    #expect(third.preedit().text == "妳")
}

@Test func 學習權重可存檔重載() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blendkey-test-\(UInt32.random(in: 0..<UInt32.max)).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = UserPhraseStore(fileURL: url)
    store.bump(reading: "ㄋㄧˇ", value: "妳")
    store.bump(reading: "ㄋㄧˇ", value: "妳")

    let reloaded = UserPhraseStore(fileURL: url)
    #expect(reloaded.bonus(reading: "ㄋㄧˇ", value: "妳") > 2.0)
    #expect(reloaded.bonus(reading: "ㄋㄧˇ", value: "你") == 0)
}
