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

    /// UI tests run without speech output or microphone.
    private let voiceEnabled = !ProcessInfo.processInfo.arguments.contains("-uitest-no-voice")

    private var revealed: Bool { session?.revealed ?? false }

    var body: some View {
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
                    RepeatButton(text: replyText)
                }

                if let session, !session.revealed {
                    hintControls
                } else {
                    askControls
                }

                if let errorMessage {
                    WarningText(text: errorMessage)
                }
            }
            .padding(24)
        }
        .elderScreen("あれ、何だっけ？")
        .task {
            // Like the talk screen: invite the question in words, then listen, so the user need not find a button.
            guard !started else { return }
            started = true
            guard voiceEnabled else { return }
            await Speaker.shared.sayAndWait(Self.prompt)
            guard !Task.isCancelled, !voice.isListening, !isWorking, session == nil else { return }
            await voice.start(onFinish: heardQuestion)
        }
        .onDisappear {
            askTask?.cancel()
            askTask = nil
            voice.stop()
            Speaker.shared.stopEverything()
        }
    }

    /// Before a question (or after the answer): ask something new.
    @ViewBuilder private var askControls: some View {
        Text(session == nil ? Self.prompt : "ほかに思い出したいことはありますか？")
            .font(.title.bold())
        if pendingQuestion != nil {
            Text("短くお答えいただくと、前の質問とあわせて探します。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        MicButton(voice: voice, onText: heardQuestion)
        TextField("文字で聞く（例：先週会った眼鏡の人の名前）", text: $question, axis: .vertical)
            .font(.title2)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("askInput")
        BigButton(title: isWorking ? "探しています…" : "聞いてみる", systemImage: "magnifyingglass", color: Palette.orange) {
            startAsking()
        }
        .disabled(isWorking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("askSubmit")
    }

    /// While hints are shown: say a guess, ask for another hint, or ask for the answer.
    @ViewBuilder private var hintControls: some View {
        MicButton(voice: voice, idleTitle: "思い出したことを言う") { spoken in
            respond(spoken)
        }
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
        HStack(spacing: 16) {
            Button {
                show(session?.moreHint())
            } label: {
                Text("もう少しヒント").font(.title2.bold()).wrapsForLargeText().frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.bordered)
            .tint(Palette.orange)
            .accessibilityIdentifier("moreHintButton")
            Button {
                show(session?.reveal())
            } label: {
                Text("答えを教えて").font(.title2.bold()).wrapsForLargeText().frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.orange)
            .accessibilityIdentifier("revealButton")
        }
    }

    private func respond(_ words: String) {
        guard var s = session else { return }
        let reply = s.respond(to: words)
        session = s
        if reply.recalledByThemselves {
            // Named it from the hints: count it for the home screen, and celebrate with sound and vibration.
            RecallStore.add(hintsUsed: s.hintsGiven)
            replyText = reply.text
            Speaker.shared.celebrateThenSay(reply.text)
            return
        }
        say(reply.text)
    }

    private func show(_ reply: HintSession.Reply?) {
        guard let reply else { return }
        // moreHint()/reveal() mutate the session; re-read it after the call.
        say(reply.text)
    }

    private func say(_ text: String) {
        replyText = text
        Speaker.shared.say(text)
    }

    private func heardQuestion(_ spoken: String) {
        question = spoken
        startAsking()
    }

    /// Starts one question at a time (a spoken and a typed question must not run together).
    private func startAsking() {
        guard !isWorking else { return }
        askTask = Task { await ask() }
    }

    private func ask() async {
        isWorking = true
        errorMessage = nil
        replyText = nil
        session = nil
        defer { isWorking = false }
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
                guard !Task.isCancelled, !voice.isListening else { return }
                await voice.start(onFinish: heardQuestion)
            } else {
                pendingQuestion = nil
                say(first.text)
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
