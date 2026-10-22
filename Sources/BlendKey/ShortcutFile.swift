import Cocoa
import BlendKeyCore

/// 快捷文字本的檔案：Application Support/BlendKey/shortcuts.txt。
/// 每次按鍵看一下修改時間，變了才重讀（stat 一次的成本可忽略）；編輯交給使用者慣用的文字編輯器。
enum ShortcutFile {
    static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("BlendKey/shortcuts.txt")

    private static var cached = Shortcuts()
    private static var cachedModified: Date?

    static func current() -> Shortcuts {
        guard let url else { return cached }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if modified != cachedModified {
            cachedModified = modified
            cached = Shortcuts(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
        return cached
    }

    /// 選單「快捷文字本…」：沒有檔就先寫範例，然後用預設文字編輯器打開
    static func openInEditor() {
        guard let url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (Shortcuts.template + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
