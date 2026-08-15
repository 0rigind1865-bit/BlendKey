import Carbon
import Foundation

/// TIS 輸入來源註冊。注意：首次安裝後必須登出再登入，
/// 輸入法才會出現在「系統設定 › 鍵盤 › 輸入法」（Apple DTS 證實，FB23026482）。
enum InputSourceInstaller {
    static let inputSourceID = "org.blendkey.inputmethod.BlendKey"

    static func register() {
        let url = Bundle.main.bundleURL
        let status = TISRegisterInputSource(url as CFURL)
        print(status == noErr ? "已註冊輸入來源：\(url.path)" : "TISRegisterInputSource 失敗：\(status)")
        enable()
    }

    static func enable() {
        let sources = findOwnSources()
        if sources.isEmpty {
            print("目前列表找不到 BlendKey 輸入來源——首次安裝需登出再登入後，到系統設定手動加入「融鍵」。")
            return
        }
        for source in sources {
            let enableStatus = TISEnableInputSource(source)
            print(enableStatus == noErr ? "已啟用輸入來源" : "TISEnableInputSource：\(enableStatus)（可能需登出後再試）")
        }
    }

    static func disable() {
        for source in findOwnSources() {
            let status = TISDisableInputSource(source)
            print(status == noErr ? "已停用輸入來源" : "TISDisableInputSource：\(status)")
        }
        print("如要完全移除：rm -rf ~/Library/'Input Methods'/BlendKey.app")
    }

    private static func findOwnSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { source in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return id == inputSourceID
        }
    }
}
