import Cocoa
import SwiftUI

/// 切換中英時在游標旁閃現「中」／「A」的提示（0.7 秒後淡出）。
/// 與候選窗同樣採常駐單例重複使用。
final class ModeHUD {
    static let shared = ModeHUD()

    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var hideWork: DispatchWorkItem?

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
        hideWork?.cancel()
        hosting.rootView = AnyView(
            Text(chinese ? "中" : "A")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .frame(width: 54, height: 54)
        )
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
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
