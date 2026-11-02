import AVFoundation
import Speech
import SwiftUI

/// Turns the user's voice into text with Apple's speech recognizer (on-device when available).
/// Stops by itself after a few seconds of silence.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle, listening
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var text = ""
    var silenceTimeout: TimeInterval = 3

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?

    var isListening: Bool { state == .listening }

    func start(onFinish: @escaping (String) -> Void) async {
        guard state != .listening else { return }
        self.onFinish = onFinish
        text = ""
        guard await Self.requestPermissions() else {
            state = .failed("マイクと音声認識を許可してください（設定アプリ → ど忘れ相棒）。")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("いまは音声認識を使えません。文字で入力してください。")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            Self.installTap(on: input, format: format, request: request)
            engine.prepare()
            try engine.start()
            state = .listening
            resetSilenceTimer()

            task = Self.startRecognition(recognizer: recognizer, request: request) { [weak self] transcript, done, errorText in
                guard let self else { return }
                if let transcript {
                    self.text = transcript
                    self.resetSilenceTimer()
                }
                guard done else { return }
                if let errorText, self.text.isEmpty {
                    print("Speech recognition error: \(errorText)")
                    self.cleanUp()
                    self.onFinish = nil
                    self.state = .failed("うまく聞き取れませんでした。もう一度お試しいただくか、文字で入力してください。")
                } else {
                    self.stop()
                }
            }
        } catch {
            cleanUp()
            state = .failed("マイクを始められませんでした。")
        }
    }

    /// Ends listening and hands the recognized text to the caller once.
    func stop() {
        guard state == .listening else { return }
        cleanUp()
        state = .idle
        let finished = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinish
        onFinish = nil
        if !finished.isEmpty { callback?(finished) }
    }

    private func cleanUp() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // The callbacks below run on background threads. They live in nonisolated functions
    // so Swift does not treat them as main-actor code (which would crash at runtime).

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func startRecognition(
        recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let transcript = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            let errorText = error.map { "\($0)" }
            Task { @MainActor in update(transcript, done, errorText) }
        }
    }
}

/// Reads text aloud in Japanese.
@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    /// "slow" or "normal", chosen in settings (key "speechSpeed").
    var speed: String { UserDefaults.standard.string(forKey: "speechSpeed") ?? "slow" }

    func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = speed == "slow" ? AVSpeechUtteranceDefaultSpeechRate * 0.8 : AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Large microphone button shared by the talk and ask screens.
struct MicButton: View {
    let voice: VoiceInput
    let onText: (String) -> Void

    var body: some View {
        Button {
            if voice.isListening {
                voice.stop()
            } else {
                Speaker.shared.stop()
                Task { await voice.start(onFinish: onText) }
            }
        } label: {
            Label(voice.isListening ? "話し終わった" : "声で話す",
                  systemImage: voice.isListening ? "stop.circle.fill" : "mic.fill")
                .font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 100)
        }
        .buttonStyle(.borderedProminent)
        .tint(voice.isListening ? .red : .green)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("micButton")

        if voice.isListening {
            Text(voice.text.isEmpty ? "どうぞ、お話しください…" : voice.text)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = voice.state {
            Text(message).font(.title3).foregroundStyle(.red)
        }
    }
}
