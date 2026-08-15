// 產生選單列模板圖示：圓角方塊挖空「融」字（模板圖，僅 alpha 有意義）
// 用法：swift scripts/make-icon.swift Resources/BlendKey.tiff
import AppKit

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 16, height: 16) // 邏輯 16pt，pixels=32 即 @2x

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = NSRect(x: 0, y: 0, width: 16, height: 16)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: canvas.insetBy(dx: 0.5, dy: 1.5), xRadius: 3, yRadius: 3).fill()

    guard let cg = NSGraphicsContext.current?.cgContext else { fatalError("無繪圖 context") }
    cg.setBlendMode(.destinationOut) // 挖空
    let font = NSFont(name: "PingFang TC", size: 11) ?? NSFont.systemFont(ofSize: 11, weight: .medium)
    let str = NSAttributedString(string: "融", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = str.size()
    str.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2))
    cg.setBlendMode(.normal)
    return rep
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/BlendKey.tiff"
let reps = [render(pixels: 16), render(pixels: 32)]
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:]) else {
    fatalError("TIFF 產生失敗")
}
try tiff.write(to: URL(fileURLWithPath: output))

// 額外輸出 PNG 預覽（128px，僅供人工檢視，不進 bundle）
let preview = render(pixels: 128)
if let png = preview.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: output + ".preview.png"))
}
print("已輸出：\(output)")
