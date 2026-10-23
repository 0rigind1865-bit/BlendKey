import Cocoa
import SwiftUI

/// 偏好設定鍵（UserDefaults，@AppStorage 同鍵共用）
enum SettingKey {
    static let shiftToggle = "shiftToggle"
    static let rightShiftOnly = "rightShiftOnly"  // 只認右 Shift 單擊（左 Shift 常誤觸）
    static let englishHint = "englishHint"
    static let fullWidthPunctuation = "fullWidthPunctuation"
    static let autoSpacing = "autoSpacing"
    static let pageSize = "pageSize"
    static let fuzzyReading = "fuzzyReading"
    static let associations = "associations"
    static let smartInput = "smartInput"  // 智慧輸入總開關：打勾才啟動本機模型
    static let aiCompletion = "aiCompletion"
    static let smartCorrection = "smartCorrection"
    static let voiceInput = "voiceInput"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            shiftToggle: true,
            rightShiftOnly: false,
            englishHint: true,
            fullWidthPunctuation: true,
            autoSpacing: true,
            pageSize: 9,
            fuzzyReading: false,
            associations: true,
            smartInput: false,
            aiCompletion: true,
            smartCorrection: true,
            voiceInput: true,
        ])
    }
}

private struct SettingsView: View {
    @AppStorage(SettingKey.shiftToggle) private var shiftToggle = true
    @AppStorage(SettingKey.rightShiftOnly) private var rightShiftOnly = false
    @AppStorage(SettingKey.englishHint) private var englishHint = true
    @AppStorage(SettingKey.fullWidthPunctuation) private var fullWidthPunctuation = true
    @AppStorage(SettingKey.autoSpacing) private var autoSpacing = true
    @AppStorage(SettingKey.pageSize) private var pageSize = 9
    @AppStorage(SettingKey.fuzzyReading) private var fuzzyReading = false
    @AppStorage(SettingKey.associations) private var associations = true
    @AppStorage(SettingKey.smartInput) private var smartInput = false
    @AppStorage(SettingKey.aiCompletion) private var aiCompletion = true
    @AppStorage(SettingKey.smartCorrection) private var smartCorrection = true
    @AppStorage(SettingKey.voiceInput) private var voiceInput = true
    @State private var showingResetAlert = false
    @State private var didReset = false

    /// 由控制器注入：清除學習資料、開啟學習資料視窗
    var onReset: () -> Void = {}
    var onShowLearnedData: () -> Void = {}

    private var smartInputReady: Bool { SmartInput.serverPath != nil && SmartInput.modelExists }

    private var smartInputNote: String {
        if SmartInput.serverPath == nil { return "需要 llama.cpp：在終端機執行 brew install llama.cpp" }
        if !SmartInput.modelExists {
            return "需要模型檔，放在：\(SmartInput.modelURL?.path ?? "")"
        }
        return "使用台灣繁體中文開源模型 Llama-3.2-Taiwan-3B（Built with Llama），在本機執行、不連網。開啟時約佔 2.5 GB 記憶體，3 分鐘沒打字或關閉就釋放。"
    }

    /// 開關一動就立刻啟動／關閉本機模型（不用等下一次打字）
    private func syncSmartInput() {
        SmartInput.setEnabled(smartInput && (aiCompletion || smartCorrection))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var inputTab: some View {
        Form {
            Section("中英混輸") {
                Toggle("Shift 單擊切換中／英", isOn: $shiftToggle)
                Toggle("只認右 Shift（左 Shift 常誤觸的話打開）", isOn: $rightShiftOnly)
                    .disabled(!shiftToggle)
                Toggle("中英自動偵測（中打英 Tab 上字；英打注音自動切回）", isOn: $englishHint)
                Toggle("中英之間自動加空白（我愛 mac）", isOn: $autoSpacing)
                note("Shift＋字母永遠直接輸出英文字母。")
            }
            Section("中文輸入") {
                Toggle("全形標點（，。？！…）", isOn: $fullWidthPunctuation)
                Toggle("相似音修正（ㄓㄗ、ㄕㄙ、ㄣㄥ 打錯也找得到）", isOn: $fuzzyReading)
                Toggle("聯想詞（打字時提示常接的下一個詞，Tab＋數字選）", isOn: $associations)
                Picker("候選字窗每頁字數", selection: $pageSize) {
                    Text("7").tag(7)
                    Text("9").tag(9)
                }
                .pickerStyle(.segmented)
            }
            Section {
                note("設定即時生效。詞庫：小麥注音（MIT）；英文詞表：macOS 內建。")
            }
        }
        .formStyle(.grouped)
    }

    private var voiceTab: some View {
        Form {
            Section("語音輸入") {
                Toggle("單按右 Option 開始講話，再按一下結束", isOn: $voiceInput)
                note("打一半的字會先送出，講的話接在後面。講話中按退格刪一個字、繼續聽；Esc 取消。使用 Mac 內建語音辨識，在本機執行、不連網。智慧輸入有開的話，講完會再由本機模型去贅字、補標點。")
            }
        }
        .formStyle(.grouped)
    }

    private var smartTab: some View {
        Form {
            Section("智慧輸入（實驗）") {
                Toggle("啟用智慧輸入（本機 AI）", isOn: $smartInput)
                    .disabled(!smartInputReady)
                    .onChange(of: smartInput) { _, _ in syncSmartInput() }
                note(smartInputNote)
            }
            Section("功能") {
                Toggle("AI 補句（提示列最前面 ✨，按 → 接受）", isOn: $aiCompletion)
                    .onChange(of: aiCompletion) { _, _ in syncSmartInput() }
                Toggle("AI 校正（停手時自動改掉組字區的同音錯字）", isOn: $smartCorrection)
                    .onChange(of: smartCorrection) { _, _ in syncSmartInput() }
            }
            .disabled(!smartInput || !smartInputReady)
        }
        .formStyle(.grouped)
    }

    private var learningTab: some View {
        Form {
            Section("學習資料") {
                note("融鍵會記住你選過的字（單字連前文一起記，「我試」不會害到「我是」）、自動學成新詞，並記錄詞與詞的接續習慣，讓斷詞越用越準。選錯學壞的字，組字中按 Shift＋退格就忘掉。資料只存在本機（Application Support），不會離開這台電腦。")
                HStack {
                    Button("檢視學習資料…") { onShowLearnedData() }
                    Button("清除全部", role: .destructive) { showingResetAlert = true }
                    if didReset {
                        Text("已清除").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 分頁（同 macOS 系統設定）：全部擠一頁時視窗太長
    var body: some View {
        TabView {
            inputTab.tabItem { Label("輸入", systemImage: "keyboard") }
            voiceTab.tabItem { Label("語音", systemImage: "mic") }
            smartTab.tabItem { Label("智慧輸入", systemImage: "sparkles") }
            learningTab.tabItem { Label("學習資料", systemImage: "books.vertical") }
        }
        .frame(width: 440, height: 430)
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
    /// 由控制器設定：清除學習資料、開啟學習資料視窗
    var onReset: () -> Void = {}
    var onShowLearnedData: () -> Void = {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(onReset: onReset, onShowLearnedData: onShowLearnedData))
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
