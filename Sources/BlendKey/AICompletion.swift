import Foundation
import BlendKeyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI 補句：用 Apple 內建的本機模型（Apple Intelligence，完全不連網）把句子接下去。
/// 停手一下才問、新請求取消舊的；結果由呼叫端再核對組字區沒變才顯示。
/// 實驗紀錄見 experiments/ai-prediction/README.md。
enum AICompletion {
    private static var task: Task<Void, Never>?

    /// 這台 Mac 能不能用（macOS 26 以上、Apple Intelligence 已開啟）
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    static func cancel() {
        task?.cancel()
        task = nil
    }

    /// - Parameters:
    ///   - text: 目前組好的字
    ///   - before: 游標前文件裡已經有的文字（給 AI 當上下文，可以是空字串）
    ///   - completion: 在主執行緒回呼；被過濾掉或出錯就不回呼
    static func request(text: String, before: String, completion: @escaping (String) -> Void) {
        cancel()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), isAvailable else { return }
        task = Task { @MainActor in
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()  // 跟停手等待重疊，省下載入時間
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 20)
                let response = try await session.respond(to: before + text, options: options)
                guard !Task.isCancelled, let cleaned = CompletionFilter.clean(response.content, text: text, before: before)
                else { return }
                completion(cleaned)
            } catch {
                // 安全過濾（guardrailViolation）、模型忙碌等：這次就不補
                Log.general.info("AI 補句略過：\(String(describing: error), privacy: .public)")
            }
        }
        #endif
    }

    /// 實驗中最好的問法（experiments 的問法 B）
    private static let instructions = """
    你是台灣繁體中文輸入法。使用者剛打完一段文字，請把它自然地接下去，\
    像同一個人繼續打字。只輸出接下去的部分（不要重複原文），10 個字以內，\
    用台灣繁體中文與台灣用語，不要解釋。
    """
}
