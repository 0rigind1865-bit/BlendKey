import Foundation
import FoundationModels

let model = SystemLanguageModel.default
print("狀態：\(model.availability)")
print("支援繁中（zh-Hant-TW）：\(model.supportsLocale(Locale(identifier: "zh-Hant-TW")))")
print("支援語言：\(model.supportedLanguages.map { $0.maximalIdentifier }.sorted())")
