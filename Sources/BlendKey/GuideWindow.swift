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
        Shortcut(keys: "← →", detail: "移動游標回去改字或插字；游標在句中時會顯示 ‸ 標出插入位置"),
        Shortcut(keys: "1 – 9", detail: "直接選候選字（也可以用滑鼠點）"),
        Shortcut(keys: "Enter", detail: "把組好的字送出"),
        Shortcut(keys: "Esc", detail: "清掉組字中的內容／關閉候選字窗"),
    ]

    private let quick = [
        Shortcut(keys: "`（數字 1 左邊）", detail: "打開符號表：…、——、《》、→、℃、①、NT$ 等，←→ 翻頁換類別；連按兩下輸出 ` 本身"),
        Shortcut(keys: "今天＋空白", detail: "候選窗多出 2026-10-20、民國年、星期等寫法；明天、昨天、後天、前天也可以，打「現在」出時間"),
        Shortcut(keys: "Tab＋數字（聯想詞）", detail: "打字時會橫排提示你平常最常接著打的詞。先按 Tab，再按 1〜5 選（Tab 兩下＝第一個），也可以用滑鼠點；選完可以一路接下去，要送出就按 Enter。不想要就照常打字"),
        Shortcut(keys: "→（AI 補句）", detail: "智慧輸入（實驗，偏好設定開啟，約佔 2.5 GB 記憶體）。打了 6 個字以上再停一下，提示列最前面會出現 ✨ AI 幫你接下去的字，按 → 接受、或用滑鼠點"),
        Shortcut(keys: "AI 校正", detail: "智慧輸入的另一半：停一下，組字區的同音錯字會自動改掉（打的自→打的字），只會換成同音字；改錯了照常按 ↓ 換回來。兩者都用本機的台灣繁體中文開源模型，不連網"),
        Shortcut(keys: "右 Option 單擊（語音輸入）", detail: "打到一半想用講的：按一下右 Option，游標旁出現紅色聲波就開始講，再按一下結束上屏。退格刪掉最後一個字、繼續聽；Esc 取消；直接打字也會先把講的字送出再接著打。用 Mac 內建語音辨識，在本機執行、不連網。智慧輸入有開的話，講完會再由本機模型去掉「嗯、那個」等贅字並補標點"),
        Shortcut(keys: "數字＋Tab＋空白", detail: "打 1234 按 Tab，再按空白：可換成 1,234、壹仟貳佰參拾肆、新臺幣…元整、一千二百三十四"),
    ]

    private let mixed = [
        Shortcut(keys: "直接打英文", detail: "打 google 後按空白，候選窗同時列出 google／Google／GOOGLE 與中文字，數字直選；按 Enter 直接送出英文"),
        Shortcut(keys: "Shift＋字母", detail: "開始英文段（首字大寫），之後小寫字母原樣接續；再按一下 Shift 回中文，或直接打注音也會自動回中文"),
        Shortcut(keys: "長按字母／數字", detail: "直接輸出那個字元，例如按住 g 出 g、按住 5 出 5"),
        Shortcut(keys: "打數字", detail: "直接打 1.62、1mm、0.4mm 再按 Tab 就會輸出原樣；單一數字打 1 按空白即可"),
        Shortcut(keys: "Shift 單擊", detail: "整體切換中／英模式，游標旁會閃「中」或「A」（偏好設定可改成只認右 Shift）"),
        Shortcut(keys: "縮寫＋空白", detail: "快捷文字本：選單「快捷文字本…」編輯，每行「縮寫 空白 全文」；打縮寫按空白，全文排候選第一位，再按空白或 Enter 送出"),
        Shortcut(keys: "Tab", detail: "接受英文偵測提示，直接上英文字"),
    ]

    private let smart = [
        Shortcut(keys: "打錯自己會修", detail: "英文模式下誤打注音，或大寫燈亮著打注音，融鍵會自動切回中文並把已打出的字母收回重組"),
        Shortcut(keys: "越用越準", detail: "選過的字、改過的詞、詞語接續習慣都會記住，同一句話打過幾次之後就不用再改"),
        Shortcut(keys: "Shift＋退格", detail: "組字中按：游標左邊那個字「選錯了」，忘掉它的學習並重新組字"),
        Shortcut(keys: "自動造詞", detail: "一串注音被你逐字改字後上屏，就自動學成新詞"),
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
                section("快打", quick)
                section("中英混輸", mixed)
                section("自動處理", smart)

                VStack(alignment: .leading, spacing: 6) {
                    Text("小訣竅").font(.headline)
                    Text("・打「用Google搜索」：先打 ㄩㄥˋ，再打 google 按空白選 Google，接著直接打注音（反白的那個會自動選上）\n"
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
