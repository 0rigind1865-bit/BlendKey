import Foundation
import BlendKeyCore

/// 詞庫單例：首次啟動於背景載入，載妥前按鍵一律放行（不到一秒）。
enum LexiconStore {
    private(set) static var lexicon: Lexicon?
    private(set) static var englishDetector: EnglishDetector?
    private static var loading = false

    static func bootstrap() {
        guard lexicon == nil, !loading else { return }
        loading = true
        let url = Bundle.main.url(forResource: "data", withExtension: "txt", subdirectory: "data")
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: Lexicon
            if let url, let lex = try? Lexicon(contentsOf: url) {
                loaded = lex
            } else {
                Log.general.error("詞庫載入失敗（bundle 缺 data/data.txt），改用空詞庫")
                loaded = Lexicon(dataText: "")
            }
            // 英文偵測：系統內建詞表（公有領域），失敗只是少了自動偵測
            let detector = try? EnglishDetector(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"))
            DispatchQueue.main.async {
                lexicon = loaded
                englishDetector = detector
                loading = false
                Log.general.info("詞庫就緒：\(loaded.entryCount) 條；英文偵測：\(detector == nil ? "無" : "有")")
            }
        }
    }
}
