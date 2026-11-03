import AVFoundation
import CryptoKit
import os
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
    private var waiterGeneration = -1
    private var currentUtterance: ObjectIdentifier?
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

    static let voiceModeKey = "voiceMode"
    nonisolated static let log = Logger(subsystem: "io.github.tadfuji.dowasure", category: "voice")
    nonisolated static func trace(_ message: String) {
        log.info("\(message, privacy: .public)")
        print("VOICELOG \(message)")
    }

    /// True when a high-quality Japanese voice has been downloaded on this iPhone (speaks with no delay).
    static var hasHighQualityDeviceVoice: Bool {
        japaneseVoices.contains { $0.quality == .enhanced || $0.quality == .premium }
    }

    /// Which voice to use: "cloud" (Gemini, most natural; the default) or "device" (iPhone, no delay).
    var usesCloudVoice: Bool {
        guard !APIKeyStore.load(account: APIKeyStore.voiceAccount).isEmpty else { return false }
        // The maker compared both and chose Gemini (2026-11-03); the iPhone voice is the fallback.
        return UserDefaults.standard.string(forKey: Self.voiceModeKey) != "device"
    }

    /// Starts speaking without waiting.
    func say(_ text: String) {
        Task { await sayAndWait(text) }
    }

    /// Speaks and returns when speaking has finished (or was stopped).
    func sayAndWait(_ text: String) async {
        stop()
        let mine = generation
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        let cloudKey = usesCloudVoice ? APIKeyStore.load(account: APIKeyStore.voiceAccount) : ""
        Self.trace("say: cloud=\(!cloudKey.isEmpty) mode=\(UserDefaults.standard.string(forKey: Self.voiceModeKey) ?? "nil") keySaved=\(!APIKeyStore.load(account: APIKeyStore.voiceAccount).isEmpty)")
        let cloudVoiceName = UserDefaults.standard.string(forKey: Self.cloudVoiceKey) ?? CloudVoice.defaultVoiceName
        let style = Self.style(for: speed)
        if !cloudKey.isEmpty {
            let voice = CloudVoice(apiKey: cloudKey, voiceName: cloudVoiceName, style: style)
            let cacheFile = Self.cacheURL(text: text, voice: cloudVoiceName, style: style)
            if let cached = cacheFile.flatMap({ try? Data(contentsOf: $0) }), let player = try? AVAudioPlayer(data: cached) {
                // Fixed phrase already on the iPhone: plays at once.
                player.delegate = self
                self.player = player
                stopWaitingTone()
                player.play()
                await withCheckedContinuation { finished = $0; waiterGeneration = generation }
                return
            }
            if cacheFile == nil {
                // Main model first; if it has hit its daily limit, the other model (separate limit).
                for model in Self.modelsToTry() {
                    var v = voice
                    v.model = model
                    switch await playStream(v.stream(text), generation: mine) {
                    case .played: return
                    case .rateLimited: Self.markRateLimited(model); continue
                    case .failed: break
                    }
                    break
                }
                guard mine == generation else { return }
            } else if let audio = await synthesizeWithFallback(voice, text: text), mine == generation,
                      let player = try? AVAudioPlayer(data: audio) {
                if let cacheFile { try? audio.write(to: cacheFile) }
                player.delegate = self
                self.player = player
                stopWaitingTone()
                player.play()
                await withCheckedContinuation { finished = $0; waiterGeneration = generation }
                return
            }
        }
        guard mine == generation else { return }
        Self.trace("say: using built-in iPhone voice")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // A slight slowdown keeps the voice natural; slowing more makes it sound mechanical.
        utterance.rate = speed == "slow" ? AVSpeechUtteranceDefaultSpeechRate * 0.9 : AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        currentUtterance = ObjectIdentifier(utterance)
        stopWaitingTone()
        synthesizer.speak(utterance)
        await withCheckedContinuation { finished = $0; waiterGeneration = generation }
    }

    // MARK: Daily limit handling

    private static var rateLimitedUntil: [String: Date] = [:]

    private static func modelsToTry() -> [String] {
        [CloudVoice.model, CloudVoice.fallbackModel].filter { (rateLimitedUntil[$0] ?? .distantPast) < Date() }
    }

    private static func markRateLimited(_ model: String) {
        trace("voice: daily limit reached for \(model)")
        rateLimitedUntil[model] = Date().addingTimeInterval(60 * 60)
    }

    private func synthesizeWithFallback(_ voice: CloudVoice, text: String) async -> Data? {
        for model in Self.modelsToTry() {
            var v = voice
            v.model = model
            do { return try await v.synthesize(text) } catch ClaudeError.http(status: 429, _) {
                Self.markRateLimited(model)
            } catch { return nil }
        }
        return nil
    }

    // MARK: Waiting tone ("pon pon pon") while the AI thinks and the voice is prepared

    private let toneNode = AVAudioPlayerNode()
    private var toneOn = false

    /// Starts a soft, repeating three-beep tone. It stops by itself when the next voice starts.
    func startWaitingTone() {
        guard !toneOn else { return }
        prepareEngine()
        guard let pattern = Self.tonePattern(format: pcmFormat) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start() } catch { return }
        Self.loop(pattern, on: toneNode)
        toneNode.play()
        toneOn = true
    }

    func stopWaitingTone() {
        guard toneOn else { return }
        toneNode.stop()
        toneOn = false
    }

    private func prepareEngine() {
        guard !engineReady else { return }
        engine.attach(streamNode)
        engine.attach(toneNode)
        engine.connect(streamNode, to: engine.mainMixerNode, format: pcmFormat)
        engine.connect(toneNode, to: engine.mainMixerNode, format: pcmFormat)
        engineReady = true
    }

    nonisolated private static func loop(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// Three short soft beeps (pon pon pon) followed by a pause, generated in code (no sound files).
    nonisolated static func tonePattern(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let beep = 0.09, gap = 0.16, pause = 0.7
        let total = Int(rate * (3 * (beep + gap) + pause))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { out[i] = 0 }
        let beepFrames = Int(rate * beep)
        for n in 0..<3 {
            let start = Int(rate * Double(n) * (beep + gap))
            for i in 0..<beepFrames {
                let t = Double(i) / rate
                // Soft attack and decay so it sounds like "pon" rather than a sharp beep.
                let envelope = sin(Double.pi * Double(i) / Double(beepFrames))
                out[start + i] = Float(0.12 * envelope * sin(2 * Double.pi * 784 * t))
            }
        }
        return buffer
    }

    // MARK: Streaming playback (starts speaking while the rest of the audio is still arriving)

    private let engine = AVAudioEngine()
    private let streamNode = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var engineReady = false

    /// Plays streamed PCM chunks. Returns false (so the caller can fall back) if no audio arrived.
    enum StreamResult { case played, rateLimited, failed }

    private func playStream(_ chunks: AsyncThrowingStream<Data, Error>, generation mine: Int) async -> StreamResult {
        prepareEngine()
        do { try engine.start() } catch {
            Self.trace("stream: engine start failed: \(error.localizedDescription)")
            return .failed
        }
        var leftover = Data()
        var scheduled = 0
        let streamStart = Date()
        do {
            for try await chunk in chunks {
                guard mine == generation else { return .played }
                var bytes = leftover + chunk
                if bytes.count % 2 == 1 { leftover = bytes.suffix(1); bytes = bytes.dropLast() } else { leftover = Data() }
                guard let buffer = Self.makeBuffer(pcm16: bytes, format: pcmFormat) else { continue }
                Self.enqueue(buffer, on: streamNode)
                scheduled += 1
                if scheduled == 1 {
                    stopWaitingTone()
                    streamNode.play()
                    Logger(subsystem: "io.github.tadfuji.dowasure", category: "voice")
                        .info("stream first audio after \(Date().timeIntervalSince(streamStart), format: .fixed(precision: 2))s")
                }
            }
        } catch {
            Self.trace("stream: failed after \(scheduled) chunks: \(String(describing: error))")
            if scheduled == 0 {
                if case ClaudeError.http(status: 429, _) = error { return .rateLimited }
                return .failed
            }
        }
        guard scheduled > 0, mine == generation else { return scheduled > 0 ? .played : .failed }
        // An empty buffer at the end tells us when everything before it has been played.
        if let end = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1) {
            end.frameLength = 1
            let gen = generation
            await withCheckedContinuation { continuation in
                finished = continuation
                waiterGeneration = gen
                Self.schedule(end, on: streamNode) { Task { @MainActor in Speaker.shared.resumeWaiter(ifGeneration: gen) } }
            }
        }
        return .played
    }

    nonisolated private static func enqueue(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode,
                                             done: @escaping @Sendable () -> Void) {
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    nonisolated private static func makeBuffer(pcm16 data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        return buffer
    }

    /// Sentences the app always says. Their audio is kept on the iPhone so they play without waiting.
    nonisolated static let fixedPhrases = ["覚えておきたいことを、話してください。", "今日も一日、おつかれさまでした。"]

    nonisolated private static func style(for speed: String) -> String {
        speed == "slow" ? "calm, kind and warm, speaking slowly and clearly" : "calm, kind and warm"
    }

    /// Only fixed phrases are cached; answers that contain the user's records are not written to disk.
    nonisolated private static func cacheURL(text: String, voice: String, style: String) -> URL? {
        guard fixedPhrases.contains(text),
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data("\(voice)|\(style)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("voice-\(digest).wav")
    }

    /// Prepares the fixed phrases in the background (called at launch and when the voice changes).
    func prewarm() {
        let key = APIKeyStore.load(account: APIKeyStore.voiceAccount)
        guard !key.isEmpty else { return }
        let voiceName = UserDefaults.standard.string(forKey: Self.cloudVoiceKey) ?? CloudVoice.defaultVoiceName
        let style = Self.style(for: speed)
        Task.detached {
            for phrase in Self.fixedPhrases {
                guard let url = Self.cacheURL(text: phrase, voice: voiceName, style: style),
                      !FileManager.default.fileExists(atPath: url.path) else { continue }
                if let audio = try? await CloudVoice(apiKey: key, voiceName: voiceName, style: style).synthesize(phrase) {
                    try? audio.write(to: url)
                }
            }
        }
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        if engineReady { streamNode.stop() }
        player?.stop()
        player = nil
        resumeWaiter()
    }

    /// Ignores finish callbacks that belong to audio stopped earlier, so one sentence never
    /// starts while another is still being spoken.
    fileprivate func resumeWaiter(ifGeneration gen: Int) {
        guard gen == waiterGeneration else { return }
        resumeWaiter()
    }

    fileprivate func resumeWaiter() {
        finished?.resume()
        finished = nil
    }

    // Delegate callbacks may arrive off the main actor, so they hop back explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if id == self.currentUtterance { self.resumeWaiter() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if id == self.currentUtterance { self.resumeWaiter() } }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if let current = self.player, ObjectIdentifier(current) == id { self.resumeWaiter() } }
    }
}

/// Large microphone button shared by the talk and ask screens.
struct MicButton: View {
    let voice: VoiceInput
    var idleTitle = "声で話す"
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
            Label(voice.isListening ? "話し終わった" : idleTitle,
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
