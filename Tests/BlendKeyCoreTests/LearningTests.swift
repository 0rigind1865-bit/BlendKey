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

@Test func 改字一次上屏就自動造詞() {
    let store = UserPhraseStore(fileURL: nil)
    #expect(打擬界並上屏(store) == "擬界")  // 第一次：直接升格為使用者詞

    // 第二次：不用改字，直接組出「擬界」
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3ru,4" { _ = engine.handle(.character(key)) }
    #expect(engine.preedit().text == "擬界")
    // 候選窗裡也看得到這個使用者詞
    _ = engine.handle(.space)
    #expect(engine.sheetView()?.items.contains { $0.value == "擬界" } == true)
}

@Test func 沒改字的上屏不會造詞() {
    let store = UserPhraseStore(fileURL: nil)
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    for key in "su3ru,4" { _ = engine.handle(.character(key)) }
    _ = engine.handle(.enter)  // 照預設組字直接上屏
    #expect(store.entries(.word).isEmpty)  // 守門：沒有改字就不學新詞
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
    store.flush()

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
    _ = first.handle(.arrowDown)  // 游標在句尾＝指向剛打的「你」，直接開它的候選
    選字(first, "妳")
    #expect(first.handle(.enter).commitText == "是妳")

    // 第二次：同樣的注音，這次不用改就是「妳」
    let second = InputEngine(lexicon: 測試詞庫)
    second.userPhrases = store
    for key in "g4su3" { _ = second.handle(.character(key)) }
    #expect(second.preedit().text == "是妳")
}

@Test func 前文只留結尾最多兩個漢字() {
    #expect(InputEngine.contextKey("我很好") == "很好")
    #expect(InputEngine.contextKey("ok好") == "好")
    #expect(InputEngine.contextKey("好，") == "")  // 標點結尾＝句首
    #expect(InputEngine.contextKey("") == "")
}

@Test func 前文當第一個詞的上下文() {
    let store = UserPhraseStore(fileURL: nil)
    store.noteCommit(["是", "妳"])  // 使用者打過兩次「是妳」
    store.noteCommit(["是", "妳"])
    let withContext = InputEngine(lexicon: 測試詞庫)
    withContext.userPhrases = store
    withContext.leftContext = "我是"  // 2 字前文沒打過 → 退到最後 1 字「是」
    for key in "su3" { _ = withContext.handle(.character(key)) }
    #expect(withContext.preedit().text == "妳")

    let plain = InputEngine(lexicon: 測試詞庫)  // 沒有前文：維持預設
    plain.userPhrases = store
    for key in "su3" { _ = plain.handle(.character(key)) }
    #expect(plain.preedit().text == "你")
}

@Test func 分段上屏也學得到前文接續() {
    let store = UserPhraseStore(fileURL: nil)
    let engine = InputEngine(lexicon: 測試詞庫)
    engine.userPhrases = store
    engine.leftContext = "好，是"  // 只取標點後的「是」
    for key in "su3" { _ = engine.handle(.character(key)) }
    #expect(engine.handle(.enter).commitText == "你")
    #expect(store.transitionBonus(from: "是", to: "你") > 0)
    #expect(store.transitionBonus(from: "，是", to: "你") == 0)
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
    #expect(!FileManager.default.fileExists(atPath: url.path))  // 延後寫檔：連打時還沒寫
    store.flush()

    let reloaded = UserPhraseStore(fileURL: url)
    #expect(reloaded.bonus(reading: "ㄋㄧˇ", value: "妳") > 2.0)
    #expect(reloaded.bonus(reading: "ㄋㄧˇ", value: "你") == 0)
}

// MARK: - 前文選字（單字連前文一起記）

@Test func 單字選字只在同樣前文底下生效() {
    let store = UserPhraseStore(fileURL: nil)
    // 前文「是」底下把 ㄋㄧˇ 改成「妳」
    let first = InputEngine(lexicon: 測試詞庫)
    first.userPhrases = store
    first.leftContext = "是"
    for key in "su3" { _ = first.handle(.character(key)) }
    _ = first.handle(.arrowDown)
    選字(first, "妳")
    _ = first.handle(.enter)
    #expect(store.selectionBonus(after: "是", reading: "ㄋㄧˇ", value: "妳") > 0)
    #expect(store.bonus(reading: "ㄋㄧˇ", value: "妳") == 0)  // 單字不記全域

    // 同樣前文：直接是「妳」；沒有前文：仍是預設的「你」（不像全域學習會害到別句）
    let same = InputEngine(lexicon: 測試詞庫)
    same.userPhrases = store
    same.leftContext = "是"
    for key in "su3" { _ = same.handle(.character(key)) }
    #expect(same.preedit().text == "妳")
    let other = InputEngine(lexicon: 測試詞庫)
    other.userPhrases = store
    other.leftContext = "我"
    for key in "su3" { _ = other.handle(.character(key)) }
    #expect(other.preedit().text == "你")
}

@Test func Shift退格忘掉選錯的字() {
    let store = UserPhraseStore(fileURL: nil)
    let first = InputEngine(lexicon: 測試詞庫)
    first.userPhrases = store
    first.leftContext = "是"
    for key in "su3" { _ = first.handle(.character(key)) }
    _ = first.handle(.arrowDown)
    選字(first, "妳")
    _ = first.handle(.enter)

    let second = InputEngine(lexicon: 測試詞庫)
    second.userPhrases = store
    second.leftContext = "是"
    for key in "su3" { _ = second.handle(.character(key)) }
    #expect(second.preedit().text == "妳")
    #expect(second.handle(.shiftBackspace) == .consumed)
    #expect(second.preedit().text == "你")  // 學習忘掉、重算回預設
    #expect(store.selectionBonus(after: "是", reading: "ㄋㄧˇ", value: "妳") == 0)
    #expect(store.transitionBonus(from: "是", to: "妳") == 0)
    #expect(InputEngine(lexicon: 測試詞庫).handle(.shiftBackspace) == .ignored)  // 閒置時放行給 app
}

@Test func 舊版學習檔缺欄位_照樣讀得進來() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("userphrases.json")
    // 沒有 contextSelections 等新欄位的舊檔
    try Data(#"{"selections":{"ㄋㄧˇ":{"妳":3}},"transitions":{"我":{"是":2}}}"#.utf8).write(to: url)
    let store = UserPhraseStore(fileURL: url)
    #expect(store.bonus(reading: "ㄋㄧˇ", value: "妳") > 0)
    #expect(store.transitionCount == 1)
}

@Test func 學習檔壞掉_先留底不覆寫() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("userphrases.json")
    try Data("{壞掉".utf8).write(to: url)
    let store = UserPhraseStore(fileURL: url)
    store.flush()
    #expect(try Data(contentsOf: url.appendingPathExtension("bak")) == Data("{壞掉".utf8))
}
