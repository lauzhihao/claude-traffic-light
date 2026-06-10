import Foundation
import Combine
import Speech
import AVFoundation

// 端上「语音给 agent 下指令」：按住说话 -> 实时转文字，填进表单/备注。
// 注意：识别在端上做，不调后端 asr（那是抖音链接转写，语义不同）。
//
// 需要 Info.plist 权限（见 README/工程设置）：
//   NSMicrophoneUsageDescription、NSSpeechRecognitionUsageDescription
// 未授权时 start() 走 onError 回调，UI 应把语音按钮置灰，不崩。

// 不在类上加 @MainActor：会让合成的 ObservableObject 一致性变成主actor隔离，
// 与 @StateObject 的 nonisolated 要求冲突。改为在回调里显式 hop 回 @MainActor。
final class SpeechDictator: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var available: Bool = true

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var onError: ((String) -> Void)?

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.available = (status == .authorized) && (self.recognizer?.isAvailable ?? false)
            }
        }
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            onError?("语音识别暂不可用")
            return
        }
        // 麦克风 + 识别授权双检查
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            requestAuthorization()
            onError?("请在系统设置里允许语音识别")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?("音频会话启动失败：\(error.localizedDescription)")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("录音启动失败：\(error.localizedDescription)")
            teardown()
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        teardown()
        isRecording = false
    }

    private func teardown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
