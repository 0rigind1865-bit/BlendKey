import AVFoundation
import Speech

/// 語音輸入：Mac 內建語音辨識（台灣中文，強制本機辨識、不連網）。
/// 單按右 Option 開始／再按一下結束；辨識中的字以組字區顯示，結束才上屏。
/// 第一次使用會跳麥克風與語音辨識的授權視窗。
final class VoiceInput {
    static let shared = VoiceInput()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 辨識器自己結案（停頓太久）的前幾段，已經定下來的字
    private var committed = ""
    /// 目前這一段最新聽到的字（還沒定案）
    private var partial = ""
    /// 目前為止聽到的全部字
    var heard: String { committed + partial }
    /// 使用者按了結束（而不是辨識器自己停）
    private var stopping = false
    /// 定案時呼叫（結束後辨識器送回最後結果；失敗則給目前已聽到的字）
    private var onFinal: ((String) -> Void)?
    /// 字變了就回呼（退格後重開一段辨識要沿用）
    private var onPartial: ((String) -> Void)?

    /// 等授權回覆中：擋掉重複開始（兩次 begin 會對同一個 bus 裝兩次 tap 而閃退）。
    /// 不算「在聽」——切換焦點觸發的 commitComposition 不能把還沒開始的這次取消掉
    private var starting = false

    var isListening: Bool { request != nil }

    /// 開始聽。onPartial：字變了就回呼（主執行緒）；onFinal：stop() 後拿到定案文字
    func start(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isListening, !starting else { return }
        starting = true
        authorize { [weak self] granted in
            guard let self else { return }
            self.starting = false
            guard granted else {
                Log.general.error("語音輸入：沒有麥克風或語音辨識權限")
                onFinal("")
                return
            }
            self.begin(onPartial: onPartial, onFinal: onFinal)
        }
    }

    /// 結束：停止收音，等辨識器送回定案結果（本機辨識通常一下子就回）
    func stop() {
        guard isListening else { return }
        stopping = true
        stopAudio()
        request?.endAudio()
    }

    /// 立刻結束並回傳目前聽到的字（使用者直接接著打字時用，不等定案）
    @discardableResult
    func finishNow() -> String {
        let text = heard
        reset()
        return text
    }

    /// 講話中按退格：刪掉最後一個字、繼續聽。目前這段先定下來，再開新的一段接著辨識，
    /// 不然辨識器下一次回報又會把刪掉的字寫回來。
    /// ponytail: 剛講完還沒辨識出來的那零點幾秒會丟掉；嫌會漏字再改成等這段結案
    func deleteBackward() -> String {
        guard isListening, let recognizer, let onPartial else { return heard }
        committed = String(heard.dropLast())
        partial = ""
        task?.cancel()  // 舊這段晚到的回呼會被 request === 檢查擋掉
        startTask(recognizer: recognizer, onPartial: onPartial)
        return heard
    }

    private func begin(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Log.general.error("語音輸入：這台 Mac 不能在本機辨識台灣中文")
            onFinal("")
            return
        }
        self.onFinal = onFinal
        self.onPartial = onPartial
        committed = ""
        partial = ""
        stopping = false

        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)  // 停頓後換新的一段辨識，聲音接著餵給新的
        }
        do {
            audio.prepare()
            try audio.start()
        } catch {
            Log.general.error("語音輸入：麥克風啟動失敗 \(String(describing: error), privacy: .public)")
            reset()
            onFinal("")
            return
        }
        Log.general.info("語音輸入：開始聽")
        startTask(recognizer: recognizer, onPartial: onPartial)
    }

    /// 開一段辨識。停頓太久辨識器會自己結案：這時把這段存進 committed、再開新的一段繼續聽，
    /// 使用者按結束（stopping）才真的結束並回傳全部。
    private func startTask(recognizer: SFSpeechRecognizer, onPartial: @escaping (String) -> Void) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // 不連網：聲音不離開這台電腦
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        partial = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                // 舊的辨識（已被 finishNow／新的 start 取代）晚到的回呼不理
                guard let self, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    // ponytail: 辨識器有時不結案、直接從頭重算（字突然變很短）：把舊的先存起來
                    if text.count * 2 < self.partial.count { self.committed += self.partial }
                    self.partial = text
                    if !result.isFinal { onPartial(self.heard) }
                }
                guard result?.isFinal == true || error != nil else { return }
                if !self.stopping && self.audio.isRunning {
                    self.committed += self.partial
                    self.task?.cancel()
                    Log.general.info("語音輸入：停頓結案，接著聽（已有 \(self.committed.count, privacy: .public) 字）")
                    self.startTask(recognizer: recognizer, onPartial: onPartial)
                    return
                }
                let text = self.heard
                let deliver = self.onFinal
                self.reset()
                Log.general.info("語音輸入：結束（\(text.count, privacy: .public) 字）")
                deliver?(text)
            }
        }
    }

    private func stopAudio() {
        guard audio.isRunning else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
    }

    private func reset() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        onFinal = nil
        onPartial = nil
        committed = ""
        partial = ""
        stopping = false
    }

    /// 麥克風＋語音辨識兩種權限都要（第一次會跳系統詢問視窗）
    private func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        }
    }
}
