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

@Test func 打字中即時提示_橫排_Tab兩下選第一個並接龍() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")  // 你好
    let view = engine.associationView()
    #expect(view?.items.map(\.value) == ["世界"])
    #expect(view?.items.first?.label == "1")
    #expect(view?.horizontal == true)
    #expect(view?.anchorUTF16 == 0)  // 對齊最後一個詞「你好」的開頭
    #expect(view?.highlightedInPage == -1)
    type(engine, "g")  // 打注音打到一半：提示維持，不閃
    #expect(engine.associationView()?.items.map(\.value) == ["世界"])

    _ = engine.handle(.tab)  // 進入選擇：第一個反白
    #expect(engine.associationView()?.highlightedInPage == 0)
    _ = engine.handle(.tab)  // 換掉打到一半的注音
    #expect(engine.preedit().text == "你好世界")
    #expect(engine.associationView()?.items.map(\.value) == ["是"])  // 接龍
    #expect(engine.handle(.enter).commitText == "你好世界")
    #expect(engine.associationView() == nil)  // 上屏後不提示（Tab 屬於 app）
}

@Test func 滑鼠點選聯想詞與候選字() {
    let (engine, store) = engineWithHabits()
    store.noteCommit(["你好", "是"])
    store.noteCommit(["你好", "是"])
    type(engine, "su3cl3")
    #expect(engine.associationView()?.items.map(\.value) == ["世界", "是"])
    _ = engine.click(itemAt: 1)
    #expect(engine.preedit().text == "你好是")
    _ = engine.handle(.backspace)

    _ = engine.handle(.tab)
    _ = engine.handle(.character("2"))  // Tab＋2：選第二個
    #expect(engine.preedit().text == "你好是")
    _ = engine.handle(.backspace)
    _ = engine.handle(.tab)
    _ = engine.handle(.escape)  // Tab 後 Esc：只取消選擇
    #expect(engine.preedit().text == "你好")
    _ = engine.handle(.character("2"))  // 已取消：2 照常是注音 ㄉ
    #expect(engine.preedit().text == "你好ㄉ")
    _ = engine.handle(.escape)
    type(engine, "su3cl3")

    _ = engine.handle(.arrowLeft)  // 回頭改字：不提示聯想
    #expect(engine.associationView() == nil)
    _ = engine.handle(.arrowDown)  // 開候選窗，點第 2 個
    let second = engine.sheetView()?.items[1].value
    _ = engine.click(itemAt: 1)
    #expect(engine.sheetView() == nil)
    #expect(second != nil && engine.preedit().text.contains(second!))
}

@Test func 聯想詞不擋打字() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")
    _ = engine.handle(.character("!"))  // Shift+1 照常是全形驚嘆號
    #expect(engine.preedit().text == "你好！")
    _ = engine.handle(.escape)  // Esc 照常清組字區
    #expect(engine.isIdle)

    engine.associationsEnabled = false
    type(engine, "su3cl3")
    #expect(engine.associationView() == nil)
}

// MARK: - AI 補句

@Test func AI補句顯示在提示列最前面_右鍵接受_組字區一變就作廢() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")
    #expect(engine.completionContext == "你好")
    engine.aiCompletion = "世界和平"
    let view = engine.associationView()
    #expect(view?.items.map(\.value) == ["世界和平", "世界"])
    #expect(view?.items.first?.label == "✨→")

    _ = engine.handle(.tab)  // Tab 選擇仍是聯想詞：反白跳過補句
    #expect(engine.associationView()?.highlightedInPage == 1)
    _ = engine.handle(.escape)

    _ = engine.handle(.arrowRight)
    #expect(engine.preedit().text == "你好世界和平")
    #expect(engine.aiCompletion == nil)

    engine.aiCompletion = "測試"
    type(engine, "su3")  // 又打了字：舊補句作廢
    #expect(engine.aiCompletion == nil)
    _ = engine.handle(.arrowLeft)
    #expect(engine.completionContext == nil)  // 游標回頭改字：不問 AI
}

@Test func AI補句滑鼠點選() {
    let (engine, _) = engineWithHabits()
    type(engine, "su3cl3")
    engine.aiCompletion = "世界和平"
    _ = engine.click(itemAt: 1)  // 第 2 格是聯想詞「世界」
    #expect(engine.preedit().text == "你好世界")
    engine.aiCompletion = "和平"
    _ = engine.click(itemAt: 0)
    #expect(engine.preedit().text == "你好世界和平")
}

@Test func AI補句輸出過濾() {
    #expect(CompletionFilter.clean("已經到貨了。謝謝", text: "這批貨", before: "") == "已經到貨了")
    #expect(CompletionFilter.clean("現在才看到，等一下回你。", text: "我剛剛在開會", before: "")
            == "現在才看到，等一下回你")  // 補整句：逗號不停
    #expect(CompletionFilter.clean("這批貨已經到了", text: "這批貨", before: "") == "已經到了")  // 重打原文
    #expect(CompletionFilter.clean("庫>都市醫武狂尊>第1", text: "我的書", before: "") == nil)  // 網頁殘渣
    #expect(CompletionFilter.clean("寫字寫字寫字寫字", text: "他", before: "") == nil)  // 鬼打牆
    #expect(CompletionFilter.clean("  ", text: "你好", before: "") == nil)
}

// MARK: - AI 校正

@Test func AI校正只採用同音的改動_改到的詞可再改回() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "su3cl3")  // 你好
    let target = engine.correctionTarget
    #expect(target?.text == "你好")
    #expect(target?.readings == ["ㄋㄧˇ", "ㄏㄠˇ"])

    #expect(engine.applyCorrection("妳好", to: "你好"))  // 妳＝ㄋㄧˇ 同音：採用
    #expect(engine.preedit().text == "妳好")
    #expect(!engine.applyCorrection("妳高", to: "妳好"))  // 高＝ㄍㄠ 不同音：不採用
    #expect(engine.preedit().text == "妳好")
    #expect(!engine.applyCorrection("你好嗎", to: "妳好"))  // 字數不對
    #expect(!engine.applyCorrection("你好", to: "舊句子"))  // 組字區已經變了

    _ = engine.handle(.arrowDown)  // 改到的詞照常能按 ↓ 換回來
    #expect(engine.sheetView()?.items.map(\.value).contains("你好") == true)
}

@Test func AI校正可以跨過標點_標點本身不改() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "su3<cl3")  // 你，好
    #expect(engine.preedit().text == "你，好")
    #expect(engine.correctionTarget?.readings == ["ㄋㄧˇ", nil, "ㄏㄠˇ"])
    #expect(engine.applyCorrection("妳，好", to: "你，好"))
    #expect(engine.preedit().text == "妳，好")
    #expect(!engine.applyCorrection("妳。好", to: "妳，好"))  // 標點不能改
}

@Test func AI校正的文法只允許同音字() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "su3<cl3")  // 你，好
    #expect(engine.correctionGrammar == #"root ::= ("你" | "妳" | "擬") ("，") ("好")"#)
}

@Test func AI校正不碰夾英文的組字區() {
    let engine = InputEngine(lexicon: 測試詞庫)
    type(engine, "su3")
    _ = engine.handle(.englishLiteral("A"))
    _ = engine.handle(.escape)  // 結束英文段
    #expect(engine.correctionTarget == nil)
}
