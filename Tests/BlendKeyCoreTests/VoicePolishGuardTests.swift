import Testing
@testable import BlendKeyCore

private let 讀音 = Lexicon(dataText: """
ㄉㄨˇ 賭 -5.0
ㄉㄨˇ 堵 -6.0
ㄏㄨㄞˋ 壞 -5.0
ㄗㄞˋ 在 -4.0
ㄗㄞˋ 再 -4.5
ㄕˋ 是 -4.0
ㄕˋ 試 -5.0
""")

@Test func 語音整理保險_同音字贅字標點可以() {
    #expect(VoicePolishGuard.isSafe(original: "好像賭住了", polished: "好像堵住了。", lexicon: 讀音))
    #expect(VoicePolishGuard.isSafe(original: "還要在測是一下", polished: "還要再測試一下", lexicon: 讀音))  // 不管聲調
    #expect(VoicePolishGuard.isSafe(original: "嗯那個我明天到然後再說", polished: "我明天到，再說。", lexicon: 讀音))
    #expect(VoicePolishGuard.isSafe(original: "這個這個案子", polished: "這個案子", lexicon: 讀音))  // 重複的話
}

@Test func 語音整理保險_亂改就退回() {
    #expect(!VoicePolishGuard.isSafe(original: "好像賭住了", polished: "好像壞了", lexicon: 讀音))      // 不同音
    #expect(!VoicePolishGuard.isSafe(original: "他說他明天不來", polished: "他說明天不來", lexicon: 讀音))  // 刪一般的字
    #expect(!VoicePolishGuard.isSafe(original: "我明天十點到", polished: "我明天早上十點到", lexicon: 讀音))  // 自己加字
}
