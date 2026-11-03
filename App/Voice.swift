import AVFoundation
import DowasureCore
import Speech
import SwiftUI

/// Turns the user's voice into text with Apple's speech recognizer (on-device when available).
/// Stops by itself after silence (long wait before the first words, short pause after speaking).
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle, listening
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var text = ""

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
        let timeout = VoiceTiming.silenceTimeout(heardSomething: !text.isEmpty)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.timedOut() }
        }
    }

    /// Silence timer fired: finish the answer, or explain why the microphone stopped.
    private func timedOut() {
        guard state == .listening else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanUp()
            onFinish = nil
            state = .failed("お話が聞こえなかったので、いったん止めました。もう一度「声で話す」を押してください。")
        } else {
            stop()
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

/// Reads text aloud in Japanese. Uses the natural cloud voice when its key is set,
/// and the built-in iPhone voice otherwise (or when the cloud request fails).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// "slow" or "normal", chosen in settings (key "speechSpeed").
    var speed: String { UserDefaults.standard.string(forKey: "speechSpeed") ?? "slow" }

    static let voiceKey = "voiceIdentifier"
    static let cloudVoiceKey = "cloudVoiceName"

    /// Regular Japanese voices installed on this iPhone, female first, then most natural.
    /// Only Apple's standard voices ("com.apple.voice.*") are offered: the character voices
    /// ("com.apple.eloquence.*" such as Eddy or Grandpa) sound deliberately mechanical and scared the user.
    static var japaneseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { isRegularJapanese($0.identifier) && $0.language == "ja-JP" }
            .sorted { a, b in
                let af = a.gender == .female, bf = b.gender == .female
                if af != bf { return af }
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func isRegularJapanese(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.voice.") && !identifier.contains("super-compact")
    }

    /// The built-in voice chosen in settings, or the most suitable regular voice.
    var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Self.voiceKey), Self.isRegularJapanese(id),
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        return Self.japaneseVoices.first ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }

    var usesCloudVoice: Bool { !APIKeyStore.load(account: APIKeyStore.voiceAccount).isEmpty }

    /// Starts speaking without waiting.
    func say(_ text: String) {
        Task { await sayAndWait(text) }
    }

    /// Speaks and returns when speaking has finished (or was stopped).
    func sayAndWait(_ text: String) async {
        stop()
        generation += 1
        let mine = generation
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        let cloudKey = APIKeyStore.load(account: APIKeyStore.voiceAccount)
        var cloudPlayer: AVAudioPlayer?
        let cloudVoiceName = UserDefaults.standard.string(forKey: Self.cloudVoiceKey) ?? CloudVoice.defaultVoiceName
        let style = speed == "slow" ? "calm, kind and warm, speaking slowly and clearly" : "calm, kind and warm"
        if !cloudKey.isEmpty,
           let audio = try? await CloudVoice(apiKey: cloudKey, voiceName: cloudVoiceName, style: style).synthesize(text) {
            cloudPlayer = try? AVAudioPlayer(data: audio)
        }
        guard mine == generation else { return }
        if let player = cloudPlayer {
            player.delegate = self
            self.player = player
            player.play()
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            // A slight slowdown keeps the voice natural; slowing more makes it sound mechanical.
            utterance.rate = speed == "slow" ? AVSpeechUtteranceDefaultSpeechRate * 0.9 : AVSpeechUtteranceDefaultSpeechRate
            utterance.postUtteranceDelay = 0.2
            synthesizer.speak(utterance)
        }
        await withCheckedContinuation { finished = $0 }
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        resumeWaiter()
    }

    private func resumeWaiter() {
        finished?.resume()
        finished = nil
    }

    // Delegate callbacks may arrive off the main actor, so they hop back explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeWaiter() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeWaiter() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resumeWaiter() }
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
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = voice.state {
            Text(message).font(.title2).foregroundStyle(.red)
        }
    }
}
