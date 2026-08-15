// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BlendKey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlendKey", targets: ["BlendKey"]),
        .executable(name: "blendkey-cli", targets: ["blendkey-cli"]),
    ],
    targets: [
        // 純邏輯核心：零 AppKit 依賴，Swift 6 嚴格模式，全部可單元測試
        .target(name: "BlendKeyCore"),
        // IMK 殼層：IMK 未標註併發，用 Swift 5 語言模式避開衝突
        .executableTarget(
            name: "BlendKey",
            dependencies: ["BlendKeyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 開發用 REPL：不安裝輸入法也能驗證整條組字管線
        .executableTarget(name: "blendkey-cli", dependencies: ["BlendKeyCore"]),
        .testTarget(name: "BlendKeyCoreTests", dependencies: ["BlendKeyCore"]),
    ]
)
