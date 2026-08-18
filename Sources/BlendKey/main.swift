import Cocoa
import InputMethodKit
import BlendKeyCore

// 必須與 Info.plist 的 InputMethodConnectionName 一字不差
let kConnectionName = "org.blendkey.inputmethod.BlendKey_Connection"

// install / uninstall 子命令：TIS 註冊／停用後直接結束，供 install.sh 呼叫
if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "install":
        InputSourceInstaller.register()
        exit(0)
    case "uninstall":
        InputSourceInstaller.disable()
        exit(0)
    case "guide", "learned":
        // 開發用：直接開啟視窗，供產生說明文件截圖（scripts/capture-shots.sh）
        SettingKey.registerDefaults()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments[1] == "guide" {
            GuideWindowController.shared.show()
        } else {
            let store = UserPhraseStore(
                fileURL: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("BlendKey/userphrases.json"))
            LearnedDataWindowController.shared.show(store: store)
        }
        app.run()
    default:
        FileHandle.standardError.write(Data("用法：BlendKey [install|uninstall]\n".utf8))
        exit(1)
    }
}

guard let bundleID = Bundle.main.bundleIdentifier else {
    FileHandle.standardError.write(Data("錯誤：必須以 BlendKey.app 形式執行\n".utf8))
    exit(1)
}

SettingKey.registerDefaults()

// IMKServer 必須以強參考存活整個行程，否則系統連不上輸入法
let server = IMKServer(name: kConnectionName, bundleIdentifier: bundleID)
guard server != nil else {
    Log.general.error("IMKServer 建立失敗")
    exit(1)
}
Log.general.info("融鍵已啟動（connection: \(kConnectionName, privacy: .public)）")

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
