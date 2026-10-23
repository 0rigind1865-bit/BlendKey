import Cocoa
import SwiftUI

/// 切換中英時在游標旁閃現「中」／「A」的提示（0.7 秒後淡出）；語音輸入中顯示聲波。
/// 與候選窗同樣採常駐單例重複使用。
final class ModeHUD {
    static let shared = ModeHUD()

    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var hideWork: DispatchWorkItem?
    /// 第幾次 show：淡出結束時比對，期間又 show 過就不收起來
    private var shown = 0

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 54, height: 54),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect
    }

    func flash(chinese: Bool, near lineRect: NSRect) {
        show(
            Text(chinese ? "中" : "A")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .frame(width: 54, height: 54),
            near: lineRect
        )
        hide(after: 0.7)
    }

    /// 語音輸入中：游標旁顯示跳動的聲波，直到 hide()
    func showListening(near lineRect: NSRect) {
        show(
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: true)
                .frame(width: 54, height: 54),
            near: lineRect
        )
    }

    func hide(after delay: TimeInterval = 0) {
        let generation = shown
        let work = DispatchWorkItem { [weak self, panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                // 淡出途中又 show 了（例如 Shift 切換後馬上按右 Option）：不要把新的關掉
                guard self?.shown == generation else { return }
                panel.orderOut(nil)
            }
        }
        hideWork?.cancel()
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show(_ content: some View, near lineRect: NSRect) {
        hideWork?.cancel()
        shown += 1
        hosting.rootView = AnyView(content)
        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - 8 - 54)
        let screen = NSScreen.screens.first { NSPointInRect(lineRect.origin, $0.frame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = lineRect.maxY + 8 }
            origin.x = min(max(visible.minX, origin.x), visible.maxX - 54)
            if lineRect == .zero {  // 拿不到游標位置就放螢幕中下
                origin = NSPoint(x: visible.midX - 27, y: visible.minY + visible.height * 0.18)
            }
        }
        panel.setFrameOrigin(origin)
        // 用 0 秒動畫蓋掉還在跑的淡出（直接設 alphaValue 會被淡出的下一格改回去）
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.orderFrontRegardless()
    }
}
