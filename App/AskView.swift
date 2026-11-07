import SwiftUI
import SwiftData
import DowasureCore

/// "What was it again?" Gives hints first so the user can recall by themselves;
/// the answer (with the record's date) comes when they name it or ask for it.
struct AskView: View {
    static let prompt = "何を思い出したいですか？"

    @Environment(\.modelContext) private var context
    @State private var question = ""
    @State private var guess = ""
    @State private var isWorking = false
    @State private var session: HintSession?
    @State private var replyText: String?
    @State private var errorMessage: String?
    @State private var voice = VoiceInput()
    /// The running question, cancelled when the user leaves the screen.
    @State private var askTask: Task<Void, Never>?
    /// The question being answered, shown above the hints so a mis-heard question can be noticed.
    @State private var askedQuestion: String?
    /// Set after "not found, when was it?": the next short reply is searched together with it.
    @State private var pendingQuestion: String?
    @State private var started = false
    /// From opening the screen until the microphone starts (the prompt is being said).
    @State private var waitingToListen = false
    /// Changes with every new question; an older question that is still speaking must not
    /// start the microphone or clear the "searching" state of the newer one.
    @State private var askGeneration = 0
    /// Speaking a hint and then listening for the guess; replaced by the next hint or answer.
    @State private var hintTask: Task<Void, Never>?
    /// The user chose to type the guess instead of saying it.
    @State private var typingGuess = false

    /// UI tests run without speech output or microphone.
    private let voiceEnabled = !ProcessInfo.processInfo.arguments.contains("-uitest-no-voice")

    var body: some View {
        // Top half: only things to read (the question, the hint, what the microphone hears).
        // Bottom half: every button, within reach of the right thumb (藤川さん, 2026-11-07).
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let askedQuestion {
                    Text("「\(askedQuestion)」について")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("askedQuestion")
                }
                if let replyText {
                    Text(replyText)
                        .font(.title.bold())
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("answerText")
                }
                if !inHints {
                    Text(session == nil ? Self.prompt : "ほかに思い出したいことはありますか？")
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if pendingQuestion != nil {
                        Text("短くお答えいただくと、前の質問とあわせて探します。")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                MicStatus(voice: voice)
                if let errorMessage {
                    WarningText(text: errorMessage)
                }
            }
            .padding(24)
        }
        .elderScreen("あれ、何だっけ？") {
            if inHints {
                hintControls
            } else {
                askControls
            }
        }
        .task {
            // Like the talk screen: invite the question in words, then listen, so the user need not find a button.
            guard !started else { return }
            started = true
            guard voiceEnabled else { return }
            waitingToListen = true
            await Speaker.shared.sayAndWait(Self.prompt)
            // "話し終わった" pressed, a typed question started, or the screen was left: do not listen.
            guard !Task.isCancelled, waitingToListen, !voice.isListening, !isWorking, session == nil else {
                waitingToListen = false
                return
            }
            await voice.start(onFinish: heardQuestion)
            waitingToListen = false
        }
        .onDisappear {
            askTask?.cancel()
            askTask = nil
            hintTask?.cancel()
            hintTask = nil
            // cancel, not stop: stop would hand a half-heard guess to respond(), which would speak
            // another hint and open the microphone again on the home screen.
            voice.cancel()
            Speaker.shared.stopEverything()
        }
    }

    /// Hints are being given (not yet answered).
    private var inHints: Bool {
        if let session { return !session.revealed }
        return false
    }

    /// Before a question (or after the answer): ask something new. Placed in the bottom area.
    @ViewBuilder private var askControls: some View {
        if let replyText {
            // "見当たりません。いつ頃…？" listens after it is said; saying it again must not open
            // the microphone in the middle (the earlier question's task is stopped first).
            RepeatButton(text: replyText) {
                askTask?.cancel()
                voice.cancel()
                Speaker.shared.say(replyText)
            }
        }
        MicButton(voice: voice, idleTitle: "声でたずねる", waitingToListen: waitingToListen,
                  onCancelWaiting: cancelWaiting, onText: heardQuestion)
        TextField("文字で聞く（例：先週会った眼鏡の人の名前）", text: $question, axis: .vertical)
            .font(.title2)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("askInput")
        // Shown once something is typed (or while searching), so the bottom area stays short.
        if isWorking || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BigButton(title: isWorking ? "探しています…" : "聞いてみる", systemImage: "magnifyingglass",
                      color: Palette.orange, height: Style.dockButtonHeight) {
                startAsking()
            }
            .disabled(isWorking)
            .accessibilityIdentifier("askSubmit")
        }
    }

    /// While hints are shown: say a guess, ask for another hint, or ask for the answer.
    /// Speaking is the main way; typing is folded away so the bottom area has only a few big choices.
    @ViewBuilder private var hintControls: some View {
        MicButton(voice: voice, idleTitle: "思い出したことを言う") { spoken in
            respond(spoken)
        }
        HStack(spacing: 12) {
            Button {
                show(session?.moreHint())
            } label: {
                Text("もう少しヒント").font(.title2.bold()).wrapsForLargeText().frame(maxWidth: .infinity, minHeight: Style.dockButtonHeight)
            }
            .buttonStyle(.bordered)
            .tint(Palette.orange)
            .accessibilityIdentifier("moreHintButton")
            Button {
                show(session?.reveal())
            } label: {
                Text("答えを教えて").font(.title2.bold()).wrapsForLargeText().frame(maxWidth: .infinity, minHeight: Style.dockButtonHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.orange)
            .accessibilityIdentifier("revealButton")
        }
        // Without voice (or once asked for), the typing field is shown.
        if typingGuess || !voiceEnabled {
            TextField("文字で答える", text: $guess)
                .font(.title2)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("guessInput")
            if !guess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    let text = guess
                    guess = ""
                    respond(text)
                } label: {
                    Label("送る", systemImage: "paperplane.fill")
                        .font(.title2.bold())
                        .wrapsForLargeText()
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.orange)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("sendGuess")
            }
        } else {
            HStack(spacing: 12) {
                if let replyText {
                    // Through speak(): stops the microphone and the earlier hint first,
                    // and opens the microphone again only after the hint has been said once more.
                    RepeatButton(text: replyText) { repeatHint(replyText) }
                }
                Button {
                    voice.cancel()
                    Speaker.shared.stop()
                    typingGuess = true
                } label: {
                    Label("文字で答える", systemImage: "keyboard")
                        .font(.title2.bold())
                        .wrapsForLargeText()
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("typeGuessButton")
            }
        }
    }

    private func respond(_ words: String) {
        guard var s = session else { return }
        let reply = s.respond(to: words)
        session = s
        if reply.recalledByThemselves {
            // Named it from the hints: count it for the home screen, and celebrate with sound and vibration.
            // The microphone does not open again: the question is over.
            hintTask?.cancel()
            voice.cancel()
            RecallStore.add(hintsUsed: s.hintsGiven)
            replyText = reply.text
            Speaker.shared.celebrateThenSay(reply.text)
            return
        }
        speak(reply)
    }

    private func show(_ reply: HintSession.Reply?) {
        guard let reply else { return }
        // moreHint()/reveal() mutate the session; re-read it after the call.
        speak(reply)
    }

    private func say(_ text: String) {
        replyText = text
        Speaker.shared.say(text)
    }

    /// A hint ends with "言ってみてください", so the microphone opens by itself once it has been said.
    /// The answer (revealed) is only said.
    private func speak(_ reply: HintSession.Reply) {
        hintTask?.cancel()
        voice.cancel()
        guard voiceEnabled, !reply.revealed else {
            say(reply.text)
            return
        }
        replyText = reply.text
        hintTask = Task {
            await Speaker.shared.sayAndWait(reply.text)
            // Not while the user is typing the guess.
            guard !Task.isCancelled, session?.revealed == false, !typingGuess, !voice.isListening else { return }
            await voice.start(onFinish: respond)
        }
    }

    /// "話し終わった" before the microphone started: stop the prompt and do not listen.
    private func cancelWaiting() {
        waitingToListen = false
        Speaker.shared.stop()
        voice.cancel()
    }

    private func repeatHint(_ text: String) {
        speak(HintSession.Reply(text: text, revealed: session?.revealed ?? true))
    }

    private func heardQuestion(_ spoken: String) {
        question = spoken
        startAsking()
    }

    /// Starts one question at a time (a spoken and a typed question must not run together).
    private func startAsking() {
        guard !isWorking else { return }
        waitingToListen = false
        // The previous question may still be speaking "見当たりません…" (isWorking is already false then).
        askTask?.cancel()
        hintTask?.cancel()
        voice.cancel()
        askGeneration += 1
        let mine = askGeneration
        askTask = Task { await ask(generation: mine) }
    }

    private func ask(generation: Int) async {
        isWorking = true
        errorMessage = nil
        replyText = nil
        session = nil
        typingGuess = false
        defer { if generation == askGeneration { isWorking = false } }
        let full = Answerer.followUpQuestion(previous: pendingQuestion, reply: question)
        // True when the reply was joined to the earlier question; false when it is a new question.
        let joined = full != question.trimmingCharacters(in: .whitespacesAndNewlines)
        askedQuestion = full
        do {
            Speaker.shared.startWaitingTone()
            let answerer = Answerer(client: ClaudeClient(apiKey: APIKeyStore.load()))
            let answer = try await answerer.answer(full, records: RecordStore.allRecords(context))
            // The user went back home while waiting: do not speak the hint over the home screen.
            guard !Task.isCancelled else { return }
            var s = HintSession(answer: answer)
            let first = s.start()
            session = s
            question = ""
            if case .notFound = answer.kind {
                // Keep the first question, so "先週" said next is searched together with it.
                if !joined { pendingQuestion = full }
                replyText = first.text
                isWorking = false  // the search is over; only speaking and listening remain
                guard voiceEnabled else { return }
                // The reply ends with a question ("when was it?"), so listen for the answer right away.
                await Speaker.shared.sayAndWait(first.text)
                guard !Task.isCancelled, generation == askGeneration, !voice.isListening else { return }
                await voice.start(onFinish: heardQuestion)
            } else {
                pendingQuestion = nil
                speak(first)
            }
        } catch {
            Speaker.shared.stopWaitingTone()
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            // Said aloud as well: the user may not be looking at the screen while waiting.
            Speaker.shared.say(error.localizedDescription)
        }
    }
}
