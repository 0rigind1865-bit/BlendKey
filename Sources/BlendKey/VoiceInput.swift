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
    /// 收到的最新一段字（還沒定案）
    private(set) var partial = ""
    /// 定案時呼叫（結束後辨識器送回最後結果；失敗則給目前已聽到的字）
    private var onFinal: ((String) -> Void)?

    var isListening: Bool { request != nil }

    /// 開始聽。onPartial：字變了就回呼（主執行緒）；onFinal：stop() 後拿到定案文字
    func start(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isListening else { return }
        authorize { [weak self] granted in
            guard let self else { return }
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
        stopAudio()
        request?.endAudio()
    }

    /// 立刻結束並回傳目前聽到的字（使用者直接接著打字時用，不等定案）
    @discardableResult
    func finishNow() -> String {
        let text = partial
        reset()
        return text
    }

    private func begin(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Log.general.error("語音輸入：這台 Mac 不能在本機辨識台灣中文")
            onFinal("")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // 不連網：聲音不離開這台電腦
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        self.onFinal = onFinal
        partial = ""

        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
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

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                // 舊的辨識（已被 finishNow／新的 start 取代）晚到的回呼不理
                guard let self, self.request === request else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    if !result.isFinal { onPartial(self.partial) }
                }
                if result?.isFinal == true || error != nil {
                    let text = self.partial
                    let deliver = self.onFinal
                    self.reset()
                    Log.general.info("語音輸入：結束（\(text.count, privacy: .public) 字）")
                    deliver?(text)
                }
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
        partial = ""
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
