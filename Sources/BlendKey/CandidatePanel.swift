import Cocoa
import SwiftUI
import BlendKeyCore

/// 候選字窗內容（無狀態，每次呈現直接換 rootView）
private struct CandidateView: View {
    let sheet: InputEngine.SheetView

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(sheet.items.enumerated()), id: \.offset) { index, item in
                let highlighted = index == sheet.highlightedInPage
                HStack(spacing: 5) {
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    Text(item.value)
                        .font(.system(size: 17))
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
            }
            if sheet.pageCount > 1 {
                Text("\(sheet.pageIndex + 1)/\(sheet.pageCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(7)
        .fixedSize()
    }
}

/// 候選字窗：全行程單例、常駐重複使用（macOS 26 的 NSWindow 記憶體問題對策）。
/// 由「作用中控制器」持有 token，避免 Safari 分頁切換時舊實例晚到的 deactivate 關掉新窗。
final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()

    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var ownerID: ObjectIdentifier?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
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
        contentView = effect
    }

    /// - Parameters:
    ///   - lineRect: 游標所在行的螢幕矩形（IMKTextInput 提供）
    ///   - clientLevel: client 視窗層級，候選窗要壓在它上面
    func present(_ sheet: InputEngine.SheetView, near lineRect: NSRect, clientLevel: Int32, owner: AnyObject) {
        ownerID = ObjectIdentifier(owner)
        hosting.rootView = AnyView(CandidateView(sheet: sheet))
        let size = hosting.fittingSize
        setContentSize(size)
        level = NSWindow.Level(rawValue: max(Int(clientLevel) + 1, NSWindow.Level.popUpMenu.rawValue))

        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - 6 - size.height)
        let screen = NSScreen.screens.first { NSPointInRect(lineRect.origin, $0.frame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = lineRect.maxY + 6 }  // 螢幕底部改開在上方
            origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func dismiss(owner: AnyObject) {
        guard ownerID == nil || ownerID == ObjectIdentifier(owner) else { return }
        orderOut(nil)
        ownerID = nil
    }
}
