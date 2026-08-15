import Foundation
import BlendKeyCore

// blendkey-cli：組字管線 REPL——不安裝輸入法也能驗證整條管線。
// 控制鍵對應：<=← >=→ [=↓ ]=↑ `=退格 \=Esc !=Enter 空白=空白鍵 大寫字母=直出英文

let dataPath = CommandLine.arguments.dropFirst().first ?? "Resources/data/data.txt"

let lexicon: Lexicon
if let text = try? String(contentsOfFile: dataPath, encoding: .utf8) {
    lexicon = Lexicon(dataText: text)
    print("詞庫：\(dataPath)（\(lexicon.entryCount) 條）")
} else {
    lexicon = Lexicon(dataText: """
    ㄋㄧˇ 你 -4.0
    ㄏㄠˇ 好 -4.5
    ㄋㄧˇ-ㄏㄠˇ 你好 -6.0
    """)
    print("找不到 \(dataPath)，改用內建示範詞庫（先跑 scripts/build-data.sh）")
}

let engine = InputEngine(lexicon: lexicon)
engine.userPhrases = UserPhraseStore(fileURL: nil)  // 記憶體版：本次執行內可示範選字學習與自動造詞
engine.englishDetector = try? EnglishDetector(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"))
print("英文偵測：\(engine.englishDetector == nil ? "無" : "有（Tab 接受提示）")")
print("鍵入大千鍵序（例：su3cl3 → 你好）。控制鍵：< > [ ] ` \\ !　結束：Ctrl-D")

while true {
    print("鍵入> ", terminator: "")
    guard let line = readLine() else { break }
    for ch in line {
        let key: KeyInput
        switch ch {
        case "<": key = .arrowLeft
        case ">": key = .arrowRight
        case "[": key = .arrowDown
        case "]": key = .arrowUp
        case "`": key = .backspace
        case "\\": key = .escape
        case "!": key = .enter
        case "\t": key = .tab
        case " ": key = .space
        case let c where c.isUppercase: key = .englishLiteral(c)
        default: key = .character(ch)
        }
        let output = engine.handle(key)
        if let commit = output.commitText {
            print("【上屏】\(commit)")
        }
    }
    let preedit = engine.preedit()
    if !preedit.isEmpty {
        print("組字區：\(preedit.text)")
    }
    if let sheet = engine.sheetView() ?? engine.englishHintView() {
        let items = sheet.items.enumerated().map { index, item in
            index == sheet.highlightedInPage ? "▶\(item.label).\(item.value)" : " \(item.label).\(item.value)"
        }
        print("候選：\(items.joined(separator: "  "))　（\(sheet.pageIndex + 1)/\(sheet.pageCount) 頁）")
    }
}
