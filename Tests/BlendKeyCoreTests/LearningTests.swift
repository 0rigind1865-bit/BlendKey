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

/// 從候選窗選出指定的字（依內容找位置，不寫死數字鍵）
private func 選字(_ engine: InputEngine, _ value: String) {
    guard let sheet = engine.sheetView(),
          let index = sheet.items.firstIndex(where: { $0.value == value }) else {
        Issue.record("候選窗裡找不到「\(value)」")
        return
    }
    _ = engine.handle(.character(Character("\(index + 1)")))
}

/// 打 ㄋㄧˇ ㄐㄧㄝˋ，把兩個字都改成「擬」「界」後上屏
private func 打擬界並上屏(_ store: UserPhraseStore) -> String? {
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3ru,4" { _ = engine.handle(.character(key)) }  // ㄋㄧˇ ㄐㄧㄝˋ
    _ = engine.handle(.arrowLeft)   // ↓ 開的是游標右邊的字，所以要回到句首
    _ = engine.handle(.arrowLeft)
    _ = engine.handle(.arrowDown)   // 開第一個字的候選
    選字(engine, "擬")              // pin 擬，游標跳到第二字
    _ = engine.handle(.arrowDown)
    選字(engine, "界")              // pin 界
    return engine.handle(.enter).commitText
}

@Test func 連續兩次改字上屏自動造詞() {
    let store = UserPhraseStore(fileURL: nil)
    #expect(打擬界並上屏(store) == "擬界")  // 第一次：候補
    #expect(打擬界並上屏(store) == "擬界")  // 第二次：升格為使用者詞

    // 第三次：不用改字，直接組出「擬界」
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3ru,4" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "擬界")
    // 候選窗裡也看得到這個使用者詞
    _ = engine.handle(.space)
    #expect(engine.sheetView()?.items.contains { $0.value == "擬界" } == true)
}

@Test func 只改字一次不會造詞() {
    let store = UserPhraseStore(fileURL: nil)
    #expect(打擬界並上屏(store) == "擬界")

    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3ru,4" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text != "擬界")  // 一次只是候補，尚未成詞
}

@Test func 舊版學習檔案自動遷移() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blendkey-legacy-\(UInt32.random(in: 0..<UInt32.max)).json")
    defer { try? FileManager.default.removeItem(at: url) }
    // 第一版格式：頂層直接是 讀音 → 詞 → 次數
    try Data(#"{"ㄋㄧˇ":{"妳":3}}"#.utf8).write(to: url)

    let store = UserPhraseStore(fileURL: url)
    #expect(store.bonus(reading: "ㄋㄧˇ", value: "妳") > 2.0)  // 舊權重保留
    store.noteWordCandidate(reading: "ㄋㄧˇ-ㄐㄧㄝˋ", value: "擬界")
    store.noteWordCandidate(reading: "ㄋㄧˇ-ㄐㄧㄝˋ", value: "擬界")

    let reloaded = UserPhraseStore(fileURL: url)  // 以新格式重載
    #expect(reloaded.bonus(reading: "ㄋㄧˇ", value: "妳") > 2.0)
    #expect(reloaded.userWords(reading: "ㄋㄧˇ-ㄐㄧㄝˋ").map(\.value) == ["擬界"])
}

// MARK: - 連續文本語料（詞對）

@Test func 上屏的詞序列被記為詞對() {
    let store = UserPhraseStore(fileURL: nil)
    store.noteCommit(["是", "妳", "好"])
    #expect(store.transitionBonus(from: "是", to: "妳") > 0)
    #expect(store.transitionBonus(from: "妳", to: "好") > 0)
    #expect(store.transitionBonus(from: "是", to: "好") == 0)  // 不相鄰
    #expect(store.transitionBonus(from: "沒", to: "打過") == 0)
}

@Test func 詞對次數越多加分越高() {
    let store = UserPhraseStore(fileURL: nil)
    store.noteCommit(["是", "妳"])
    let once = store.transitionBonus(from: "是", to: "妳")
    store.noteCommit(["是", "妳"])
    #expect(store.transitionBonus(from: "是", to: "妳") > once)
}

@Test func 改過的字下次靠上下文自動出現() {
    let store = UserPhraseStore(fileURL: nil)
    // 第一次：預設組出「是你」，使用者改成「妳」後上屏
    let first = InputEngine(lexicon: 測試詞庫)
    first.userPhrases = store
    for key in "g4su3" { _ = first.handle(.character(key)) }  // ㄕˋ ㄋㄧˇ
    #expect(first.preedit().text == "是你")
    _ = first.handle(.arrowLeft)
    _ = first.handle(.arrowDown)
    選字(first, "妳")
    #expect(first.handle(.enter).commitText == "是妳")

    // 第二次：同樣的注音，這次不用改就是「妳」
    let second = InputEngine(lexicon: 測試詞庫)
    second.userPhrases = store
    for key in "g4su3" { _ = second.handle(.character(key)) }
    #expect(second.preedit().text == "是妳")
}

@Test func 未學過的組合完全不受影響() {
    let store = UserPhraseStore(fileURL: nil)
    store.noteCommit(["世界", "是", "妳"])  // 學了不相干的內容
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3cl3" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "你好")  // 原本的結果不變
}

@Test func 清除學習資料() {
    let store = UserPhraseStore(fileURL: nil)
    store.noteCommit(["是", "妳"])
    store.bump(reading: "ㄋㄧˇ", value: "妳")
    store.reset()
    #expect(store.transitionBonus(from: "是", to: "妳") == 0)
    #expect(store.bonus(reading: "ㄋㄧˇ", value: "妳") == 0)
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
