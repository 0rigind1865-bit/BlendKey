import Foundation
import Testing
@testable import BlendKeyCore

private func type(_ engine: InputEngine, _ keys: String) {
    for key in keys {
        _ = engine.handle(key == " " ? .space : .character(key))
    }
}

// MARK: - 符號表

@Test func 空組字區按反引號開符號表_選了直接上屏() {
    let engine = InputEngine(lexicon: 測試詞庫)
    #expect(engine.handle(.character("`")).handled)
    #expect(engine.sheetView()?.items.prefix(3).map(\.value) == ["…", "——", "《"])
    #expect(!engine.isIdle)  // 符號表開著：Cmd 快捷鍵才會先收窗
    #expect(engine.handle(.character("2")).commitText == "——")
    #expect(engine.sheetView() == nil)
}

@Test func 組字中插入符號_連按兩下出反引號本身() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "su3`1")  // 你＋…
    #expect(engine.preedit().text == "你…")
    type(engine, "``")
    #expect(engine.preedit().text == "你…`")
    _ = engine.handle(.character("`"))
    _ = engine.handle(.backspace)  // 符號表裡退格只收窗，不刪字
    #expect(engine.sheetView() == nil)
    #expect(engine.preedit().text == "你…`")
}

// MARK: - 數字寫法

@Test func 數字的各種寫法() {
    #expect(NumberForms.forms(of: "1234") == [
        "1234", "1,234", "壹仟貳佰參拾肆", "新臺幣壹仟貳佰參拾肆元整", "一千二百三十四", "一二三四", "１２３４",
    ])
    #expect(NumberForms.forms(of: "15").contains("十五"))
    #expect(NumberForms.forms(of: "15").contains("壹拾伍"))
    #expect(NumberForms.forms(of: "20304").contains("貳萬零參佰零肆"))
    #expect(NumberForms.forms(of: "10001000").contains("一千萬一千"))
    #expect(NumberForms.forms(of: "100001000").contains("一億零一千"))
    #expect(NumberForms.forms(of: "100000").contains("十萬"))
    #expect(NumberForms.forms(of: "0").contains("零"))
    #expect(NumberForms.forms(of: "3.14") == ["3.14", "參點壹肆", "三點一四", "３．１４"])
    #expect(NumberForms.forms(of: "1mm").isEmpty)
    #expect(NumberForms.forms(of: "1.2.3").isEmpty)
}

@Test func 數字按Tab後開候選換成大寫() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "1234")
    _ = engine.handle(.tab)
    #expect(engine.preedit().text == "1234")
    _ = engine.handle(.space)
    #expect(engine.sheetView()?.items[2].value == "壹仟貳佰參拾肆")
    _ = engine.handle(.character("3"))
    #expect(engine.handle(.enter).commitText == "壹仟貳佰參拾肆")
}

// MARK: - 日期快打

@Test func 日期的各種寫法() {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 20, 14, 5)
    let date = Calendar(identifier: .gregorian).date(from: c)!
    #expect(DateMacro.forms(for: "ㄐㄧㄣ-ㄊㄧㄢ", now: date) == [
        "2026-10-20", "2026/10/20", "2026年10月20日", "民國115年10月20日", "10月20日（二）",
    ])
    #expect(DateMacro.forms(for: "ㄇㄧㄥˊ-ㄊㄧㄢ", now: date).first == "2026-10-21")
    #expect(DateMacro.forms(for: "ㄒㄧㄢˋ-ㄗㄞˋ", now: date) == ["14:05", "下午2:05", "2026-10-20 14:05"])
    #expect(DateMacro.forms(for: "ㄋㄧˇ").isEmpty)
}

@Test func 打今天候選窗緊接著出日期_選了不記學習() {
    let lexicon = Lexicon(dataText: """
    ㄐㄧㄣ 今 -5.0
    ㄊㄧㄢ 天 -5.0
    ㄐㄧㄣ-ㄊㄧㄢ 今天 -6.0
    """)
    let engine = InputEngine(lexicon: lexicon)
    let store = UserPhraseStore(fileURL: nil)
    engine.userPhrases = store
    type(engine, "rup wu0 ")  // ㄐㄧㄣ ㄊㄧㄢ
    #expect(engine.preedit().text == "今天")
    _ = engine.handle(.space)
    let today = DateMacro.forms(for: "ㄐㄧㄣ-ㄊㄧㄢ")
    #expect(engine.sheetView()?.items.prefix(3).map(\.value) == ["今天", today[0], today[1]])
    _ = engine.handle(.character("2"))
    #expect(engine.handle(.enter).commitText == today[0])
    #expect(store.entries(.selection).isEmpty)
}

// MARK: - 聯想詞

private func engineWithHabits() -> (InputEngine, UserPhraseStore) {
    let engine = InputEngine(lexicon: 測試詞庫)
    let store = UserPhraseStore(fileURL: nil)
    for _ in 0..<2 {
        store.noteCommit(["你好", "世界"])
        store.noteCommit(["世界", "是"])
    }
    store.noteCommit(["你好", "高"])  // 只出現一次：雜訊，不提示
    engine.userPhrases = store
    return (engine, store)
}

@Test func 打字中即時提示下一個詞_Shift數字放進組字區() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")  // 你好
    #expect(engine.associationView()?.items.map(\.value) == ["世界"])
    #expect(engine.associationView()?.items.first?.label == "⇧1")
    type(engine, "g")  // 打注音打到一半：提示維持，不閃
    #expect(engine.associationView()?.items.map(\.value) == ["世界"])

    _ = engine.handle(.character("!"))  // Shift+1：換掉打到一半的注音
    #expect(engine.preedit().text == "你好世界")
    #expect(engine.associationView()?.items.map(\.value) == ["是"])  // 接龍
    #expect(engine.handle(.enter).commitText == "你好世界")
}

@Test func Enter上屏後也提示_選了直接上屏() {
    let (engine, store) = engineWithHabits()
    type(engine, "su3cl3")
    #expect(engine.handle(.enter).commitText == "你好")
    #expect(!engine.isIdle)
    #expect(engine.handle(.character("!")).commitText == "世界")
    #expect(engine.associationView()?.items.map(\.value) == ["是"])
    #expect(store.nextWords(after: "你好", limit: 5) == ["世界"])
}

@Test func 聯想詞不擋打字_Esc先收提示() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")
    _ = engine.handle(.escape)  // 第一次 Esc：只收提示
    #expect(engine.associationView() == nil)
    #expect(engine.preedit().text == "你好")
    _ = engine.handle(.character("!"))  // 收起後 Shift+1 照常是全形驚嘆號
    #expect(engine.preedit().text == "你好！")

    _ = engine.handle(.enter)
    type(engine, "su3")  // 上屏後直接打字：提示收起、照常組字
    #expect(engine.preedit().text == "你")
    _ = engine.handle(.escape)
    _ = engine.handle(.escape)
    #expect(engine.isIdle)

    engine.associationsEnabled = false
    type(engine, "su3cl3")
    #expect(engine.associationView() == nil)
}
