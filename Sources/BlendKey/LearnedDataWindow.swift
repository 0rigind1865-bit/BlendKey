import Cocoa
import SwiftUI
import BlendKeyCore

/// 學習資料檢視：看得到融鍵記住了什麼，也能逐筆刪掉學壞的。
private struct LearnedDataView: View {
    let store: UserPhraseStore

    @State private var kind: UserPhraseStore.Entry.Kind = .selection
    @State private var search = ""
    @State private var entries: [UserPhraseStore.Entry] = []

    private var filtered: [UserPhraseStore.Entry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.key.contains(search) || $0.value.contains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                ForEach(UserPhraseStore.Entry.Kind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if filtered.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "還沒有學習紀錄" : "找不到符合的項目",
                    systemImage: entries.isEmpty ? "brain" : "magnifyingglass",
                    description: Text(entries.isEmpty ? "開始打字之後，這裡會累積你的用字習慣。" : "換個關鍵字試試。")
                )
                .frame(maxHeight: .infinity)
            } else {
                Table(filtered) {
                    TableColumn(kind == .transition ? "前一個詞" : "讀音") { entry in
                        Text(entry.key).font(.system(size: 13))
                    }
                    TableColumn(kind == .transition ? "接著打" : "字詞") { entry in
                        Text(entry.value).font(.system(size: 15))
                    }
                    TableColumn("次數") { entry in
                        Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(48)
                    TableColumn("") { entry in
                        Button {
                            store.remove(entry)
                            reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("刪除這筆")
                    }
                    .width(32)
                }
            }

            Divider()
            HStack {
                Text("共 \(filtered.count) 筆")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("資料只存在這台電腦")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .searchable(text: $search, prompt: "搜尋讀音或字詞")
        .frame(minWidth: 460, minHeight: 420)
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in reload() }
    }

    private var explanation: String {
        switch kind {
        case .selection: return "你在候選字窗選過的字——選越多次，之後排得越前面。"
        case .word: return "同一串注音連續兩次被你改字後上屏，就自動學成新詞。"
        case .transition: return "從你上屏的句子學到的詞語接續習慣，讓斷詞越用越準。"
        }
    }

    private func reload() {
        entries = store.entries(kind)
    }
}

/// 學習資料視窗（單例）
final class LearnedDataWindowController {
    static let shared = LearnedDataWindowController()
    private var window: NSWindow?

    func show(store: UserPhraseStore) {
        if window == nil {
            let hosting = NSHostingController(rootView: LearnedDataView(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "融鍵學習資料"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
