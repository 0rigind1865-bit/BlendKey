import os

/// 除錯：log stream --level debug --predicate 'subsystem == "org.blendkey.inputmethod.BlendKey"'
enum Log {
    static let general = Logger(subsystem: "org.blendkey.inputmethod.BlendKey", category: "general")
    static let engine = Logger(subsystem: "org.blendkey.inputmethod.BlendKey", category: "engine")
}
