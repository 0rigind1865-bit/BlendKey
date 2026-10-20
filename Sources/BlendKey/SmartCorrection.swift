import Foundation

/// AI 校正（智慧輸入）：在本機跑開源續寫型模型 Breeze-7B-Base（llama.cpp 的 llama-server，不連網），
/// 把組字區的同音錯字改掉。偏好設定打勾才啟動伺服器（約吃 4 GB 記憶體），取消就關掉。
/// 模型不綁死：換一個 .gguf 檔（改 modelFileName）就能換更小的模型。
/// 實驗紀錄見 experiments/ai-prediction/README.md（實驗 G）。
enum SmartCorrection {
    private static let port = 39281
    private static let modelFileName = "Breeze-7B-Base-v1_0.Q3_K_M.gguf"
    private static var process: Process?
    private static var pending: DispatchWorkItem?
    private static var task: URLSessionDataTask?

    static var modelURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlendKey/models/\(modelFileName)")
    }

    static var modelExists: Bool {
        modelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// llama.cpp 的伺服器（brew install llama.cpp）
    static var serverPath: String? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isRunning: Bool { process?.isRunning == true }

    /// 偏好設定的開關：打勾才啟動、取消就關掉（每次按鍵都會呼叫，已啟動／已關閉時什麼都不做）
    static func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private static func start() {
        guard !isRunning, let server = serverPath, let model = modelURL, modelExists else { return }
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 外面包一層 sh：融鍵結束（就算當掉）伺服器也跟著結束，不會偷佔 4 GB 記憶體
        launched.arguments = [
            "-c",
            """
            "$0" "$@" & S=$!
            trap 'kill $S 2>/dev/null; exit 0' TERM INT
            while kill -0 $PPID 2>/dev/null && kill -0 $S 2>/dev/null; do sleep 2; done
            kill $S 2>/dev/null
            """,
            server, "-m", model.path, "--host", "127.0.0.1", "--port", "\(port)",
            "-ngl", "99", "-c", "1024",
        ]
        launched.standardOutput = FileHandle.nullDevice
        launched.standardError = FileHandle.nullDevice
        do {
            try launched.run()
            process = launched
            Log.general.info("AI 校正：啟動模型伺服器")
        } catch {
            Log.general.error("AI 校正：模型伺服器啟動失敗 \(String(describing: error), privacy: .public)")
        }
    }

    static func stop() {
        cancel()
        guard let running = process else { return }
        running.terminate()
        process = nil
        Log.general.info("AI 校正：關閉模型伺服器")
    }

    static func cancel() {
        pending?.cancel()
        pending = nil
        task?.cancel()
        task = nil
    }

    /// 停手 0.6 秒後問；新請求取消舊的。completion 在主執行緒回呼（失敗、逾時就不回呼）。
    /// - Parameters:
    ///   - text: 組字區的字
    ///   - before: 游標前文件裡的文字（上文）
    static func request(text: String, before: String, completion: @escaping (String) -> Void) {
        cancel()
        guard isRunning else { return }
        let work = DispatchWorkItem { send(text: text, before: before, completion: completion) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func send(text: String, before: String, completion: @escaping (String) -> Void) {
        let body: [String: Any] = [
            // 上文直接接在句子前面（另開「上文：」欄位實測反而改不到「打的自」）
            "prompt": fewShot + "錯字：\(before)\(text)\n正確：",
            "n_predict": (before.count + text.count) * 2 + 8,
            "temperature": 0,
            "stop": ["\n"],
            "cache_prompt": true,  // 範例部分每次都一樣，伺服器會快取
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/completion")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8  // 記憶體吃緊時可能很慢：太慢就這次不改
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        task = URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespaces),
                  content.hasPrefix(before)  // 上文被它改動了：整句不採用（上文已送出，不能動）
            else { return }
            let cleaned = content.dropFirst(before.count)
                .filter { !$0.isWhitespace && !"，。！？、：；「」".contains($0) }
            DispatchQueue.main.async {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Log.general.info("AI 校正：\(elapsed, privacy: .public) ms")
                completion(cleaned)
            }
        }
        task?.resume()
    }

    /// 續寫型模型照範例格式改錯字（實驗 G：錯的 10 句修好 4 句、改壞 0 句）
    private static let fewShot = """
    以下是注音輸入法打錯的同音字與改正後的句子。

    錯字：我們一起去吃反
    正確：我們一起去吃飯

    錯字：明天的會議改到下無
    正確：明天的會議改到下午

    錯字：這本書很有意思
    正確：這本書很有意思


    """
}
