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
    @State private var showingResetAlert = false
    @State private var didReset = false

    /// 由控制器注入：清除學習資料
    var onReset: () -> Void = {}

    var body: some View {
        Form {
            Section("中英混輸") {
                Toggle("Shift 單擊切換中／英", isOn: $shiftToggle)
                Toggle("中英自動偵測（中打英 Tab 上字；英打注音自動切回）", isOn: $englishHint)
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
            Section("學習資料") {
                Text("融鍵會記住你選過的字、自動學成新詞，並記錄詞與詞的接續習慣，讓斷詞越用越準。資料只存在本機（Application Support），不會離開這台電腦。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("清除全部學習資料", role: .destructive) { showingResetAlert = true }
                    if didReset {
                        Text("已清除").font(.callout).foregroundStyle(.secondary)
                    }
                }
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
        .alert("清除全部學習資料？", isPresented: $showingResetAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                onReset()
                didReset = true
            }
        } message: {
            Text("選字紀錄、自動學成的新詞、詞語接續習慣都會刪除，無法復原。內建詞庫不受影響。")
        }
    }
}

/// 偏好設定視窗（單例）。LSUIElement 行程也能取得鍵盤焦點。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    /// 由控制器設定：清除學習資料
    var onReset: () -> Void = {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(onReset: onReset))
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
