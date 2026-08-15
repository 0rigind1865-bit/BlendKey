import Cocoa
import SwiftUI

/// 偏好設定鍵（UserDefaults，@AppStorage 同鍵共用）
enum SettingKey {
    static let shiftToggle = "shiftToggle"
    static let englishHint = "englishHint"
    static let fullWidthPunctuation = "fullWidthPunctuation"
    static let pageSize = "pageSize"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            shiftToggle: true,
            englishHint: true,
            fullWidthPunctuation: true,
            pageSize: 9,
        ])
    }
}

private struct SettingsView: View {
    @AppStorage(SettingKey.shiftToggle) private var shiftToggle = true
    @AppStorage(SettingKey.englishHint) private var englishHint = true
    @AppStorage(SettingKey.fullWidthPunctuation) private var fullWidthPunctuation = true
    @AppStorage(SettingKey.pageSize) private var pageSize = 9

    var body: some View {
        Form {
            Section("中英混輸") {
                Toggle("Shift 單擊切換中／英", isOn: $shiftToggle)
                Toggle("自動偵測英文（Tab 上字）", isOn: $englishHint)
                Text("Shift＋字母永遠直接輸出英文字母。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("中文輸入") {
                Toggle("全形標點（，。？！…）", isOn: $fullWidthPunctuation)
                Picker("候選字窗每頁字數", selection: $pageSize) {
                    Text("7").tag(7)
                    Text("9").tag(9)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Text("設定即時生效。詞庫：小麥注音（MIT）；英文詞表：macOS 內建。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}

/// 偏好設定視窗（單例）。LSUIElement 行程也能取得鍵盤焦點。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "融鍵偏好設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
