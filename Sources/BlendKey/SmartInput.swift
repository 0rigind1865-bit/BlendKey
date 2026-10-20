import Foundation
import BlendKeyCore

/// 智慧輸入：在本機跑開源續寫型模型 Breeze-7B-Base（llama.cpp 的 llama-server，不連網），
/// 負責 AI 補句（把句子接下去）與 AI 校正（改掉組字區的同音錯字）。
/// 偏好設定打勾才啟動伺服器（約吃 4 GB 記憶體），取消就關掉。
/// 模型不綁死：換一個 .gguf 檔（改 modelFileName）就能換更小的模型。
/// 實驗紀錄見 experiments/ai-prediction/README.md（實驗 G）。
enum SmartInput {
    private static let port = 39281
    private static let modelFileName = "Breeze-7B-Base-v1_0.Q3_K_M.gguf"
    private static var process: Process?

    /// 補句與校正各自一條請求線：新請求只取消同一種的舊請求
    enum Kind { case completion, correction }
    private static var pending: [Kind: DispatchWorkItem] = [:]
    private static var tasks: [Kind: URLSessionDataTask] = [:]

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

    /// 沒打字多久就關掉伺服器、把約 4 GB 記憶體還給系統（使用者回報：開瀏覽器就卡）。
    /// 一打字就重新啟動（要 10～30 秒載入，這段時間不會有補句與校正）。
    /// ponytail: 固定 3 分鐘，嫌重開太常或太佔記憶體再調、或改成偏好設定
    private static let idleTimeout: TimeInterval = 180
    private static var idleStop: DispatchWorkItem?

    /// 偏好設定的開關，每次按鍵也會呼叫（當作「正在打字」）：
    /// 打勾就確保伺服器在跑並重設閒置計時，取消就關掉
    static func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        start()
        idleStop?.cancel()
        let work = DispatchWorkItem {
            Log.general.info("智慧輸入：閒置 \(Int(idleTimeout), privacy: .public) 秒，關閉模型伺服器")
            stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
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
            Log.general.info("智慧輸入：啟動模型伺服器")
        } catch {
            Log.general.error("智慧輸入：模型伺服器啟動失敗 \(String(describing: error), privacy: .public)")
        }
    }

    static func stop() {
        idleStop?.cancel()
        idleStop = nil
        cancel(.completion)
        cancel(.correction)
        guard let running = process else { return }
        running.terminate()
        process = nil
        Log.general.info("智慧輸入：關閉模型伺服器")
    }

    static func cancel(_ kind: Kind) {
        pending.removeValue(forKey: kind)?.cancel()
        tasks.removeValue(forKey: kind)?.cancel()
    }

    /// AI 補句：停手 0.25 秒後問，續寫型模型直接把「上文＋組字區」接下去，補到這句話結束
    /// （逗號不停；只停在句尾，使用者要的是一次補完整句）。
    /// completion 在主執行緒回呼（被過濾掉、失敗、逾時就不回呼）。
    static func complete(text: String, before: String, completion: @escaping (String) -> Void) {
        schedule(.completion, after: 0.25, body: [
            "prompt": before + text,
            "n_predict": 28,  // 約 30 字以內；寫越多越慢（約 15 字／秒）
            "stop": ["\n", "。", "！", "？"],
        ]) { content in
            let cleaned = CompletionFilter.clean(content, text: text, before: before)
            Log.general.info("AI 補句：「\(text, privacy: .public)」→「\(content, privacy: .public)」\(cleaned == nil ? "（過濾掉）" : "", privacy: .public)")
            cleaned.map(completion)
        }
    }

    /// AI 校正：停手 0.6 秒後問。上文放在「正確：」後面當已知開頭，模型只寫組字區那段，
    /// 而且用文法限制每一格只能選同音字（實驗 H：看得到錯字句＋只能選同音，修 5、改壞 0）。
    /// 核心 applyCorrection 再做一次同音保險。
    static func correct(text: String, before: String, grammar: String, completion: @escaping (String) -> Void) {
        schedule(.correction, after: 0.6, body: [
            "prompt": fewShot + "錯字：\(before)\(text)\n正確：\(before)",
            "n_predict": text.count * 3 + 4,
            "grammar": grammar,
        ]) { content in
            // ponytail: 除錯期間把內容記到系統紀錄（只在本機），確定穩定後改回 .private
            Log.general.info("AI 校正：送「\(text, privacy: .public)」→ 回「\(content, privacy: .public)」")
            completion(content)
        }
    }

    private static func schedule(
        _ kind: Kind, after delay: TimeInterval, body: [String: Any], handle: @escaping (String) -> Void
    ) {
        cancel(kind)
        guard isRunning else { return }
        let work = DispatchWorkItem { send(kind, body: body, handle: handle) }
        pending[kind] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func send(_ kind: Kind, body: [String: Any], handle: @escaping (String) -> Void) {
        var body = body
        body["temperature"] = 0
        body["cache_prompt"] = true  // 校正的範例、補句的上文常重複，伺服器會快取
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/completion")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8  // 記憶體吃緊時可能很慢：太慢就這次不做
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespaces)
            else { return }
            DispatchQueue.main.async {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Log.general.info("智慧輸入（\(kind == .completion ? "補句" : "校正", privacy: .public)）：\(elapsed, privacy: .public) ms")
                handle(content)
            }
        }
        tasks[kind] = task
        task.resume()
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
