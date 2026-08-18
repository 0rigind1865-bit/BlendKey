import Cocoa
import SwiftUI

/// 操作說明：一頁看完怎麼用融鍵。
private struct GuideView: View {

    private struct Shortcut: Identifiable {
        let keys: String
        let detail: String
        var id: String { keys }
    }

    private let chinese = [
        Shortcut(keys: "注音鍵", detail: "照大千（標準）鍵盤打，打完聲調就成一個字"),
        Shortcut(keys: "空白", detail: "組字中＝一聲；已有字＝打開候選字窗"),
        Shortcut(keys: "↑ ↓", detail: "候選字窗中上下選字（↓ 也可打開候選）"),
        Shortcut(keys: "← →", detail: "移動游標回去改字；候選字窗中＝翻頁"),
        Shortcut(keys: "1 – 9", detail: "直接選候選字"),
        Shortcut(keys: "Enter", detail: "把組好的字送出"),
        Shortcut(keys: "Esc", detail: "清掉組字中的內容／關閉候選字窗"),
    ]

    private let mixed = [
        Shortcut(keys: "直接打英文", detail: "打 google 後按空白，候選窗同時列出 google／Google／GOOGLE 與中文字，數字直選"),
        Shortcut(keys: "Shift＋字母", detail: "開始英文段（首字大寫），之後小寫字母原樣接續；再按一下 Shift 回中文"),
        Shortcut(keys: "長按字母／數字", detail: "直接輸出那個字元，例如按住 g 出 g、按住 5 出 5"),
        Shortcut(keys: "打數字", detail: "直接打 1.62 再按 Tab 或 Enter，就會輸出數字而不是注音"),
        Shortcut(keys: "Shift 單擊", detail: "整體切換中／英模式，游標旁會閃「中」或「A」"),
        Shortcut(keys: "Tab", detail: "接受英文偵測提示，直接上英文字"),
    ]

    private let smart = [
        Shortcut(keys: "打錯自己會修", detail: "英文模式下誤打注音，或大寫燈亮著打注音，融鍵會自動切回中文並把已打出的字母收回重組"),
        Shortcut(keys: "越用越準", detail: "選過的字、改過的詞、詞語接續習慣都會記住，同一句話打過幾次之後就不用再改"),
        Shortcut(keys: "自動造詞", detail: "同一串注音連續兩次被你改字後上屏，就自動學成新詞"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("融鍵 BlendKey")
                        .font(.system(size: 24, weight: .semibold))
                    Text("中英混輸零阻礙的注音輸入法——打字時不用切換輸入法，中文、英文、標點一氣呵成。")
                        .foregroundStyle(.secondary)
                }

                section("中文輸入", chinese)
                section("中英混輸", mixed)
                section("自動處理", smart)

                VStack(alignment: .leading, spacing: 6) {
                    Text("小訣竅").font(.headline)
                    Text("・打「用Google搜索」：先打 ㄩㄥˋ，再打 google 按空白選 Google，接著繼續打注音\n"
                         + "・不小心按到大寫燈也沒關係，繼續打注音它會自己修正回來\n"
                         + "・想看融鍵記住了什麼，開「學習資料…」，可以逐筆刪掉學壞的")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 560)
    }

    private func section(_ title: String, _ items: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.keys)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.12)))
                        .frame(width: 128, alignment: .leading)
                    Text(item.detail)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// 操作說明視窗（單例）
final class GuideWindowController {
    static let shared = GuideWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: GuideView()))
            window.title = "融鍵操作說明"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
