import SwiftUI
import SwiftData
import DowasureCore

/// "What was it again?" Gives hints first so the user can recall by themselves;
/// the answer (with the record's date) comes when they name it or ask for it.
struct AskView: View {
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

    private var revealed: Bool { session?.revealed ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let replyText {
                    Text(replyText)
                        .font(.title.bold())
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("answerText")
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
        .onDisappear {
            askTask?.cancel()
            askTask = nil
            voice.stop()
            Speaker.shared.stopEverything()
        }
    }

    /// Before a question (or after the answer): ask something new.
    @ViewBuilder private var askControls: some View {
        Text(session == nil ? "何を思い出したいですか？" : "ほかに思い出したいことはありますか？")
            .font(.title.bold())
        MicButton(voice: voice) { spoken in
            question = spoken
            startAsking()
        }
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
        HStack {
            TextField("文字で答える", text: $guess)
                .font(.title2)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("guessInput")
            Button("送る") {
                let text = guess
                guess = ""
                respond(text)
            }
            .font(.title2.bold())
            .disabled(guess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sendGuess")
        }
        HStack(spacing: 16) {
            Button {
                show(session?.moreHint())
            } label: {
                Text("もう少しヒント").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.bordered)
            .tint(Palette.orange)
            .accessibilityIdentifier("moreHintButton")
            Button {
                show(session?.reveal())
            } label: {
                Text("答えを教えて").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 72)
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
        do {
            Speaker.shared.startWaitingTone()
            let answerer = Answerer(client: ClaudeClient(apiKey: APIKeyStore.load()))
            let answer = try await answerer.answer(question, records: RecordStore.allRecords(context))
            // The user went back home while waiting: do not speak the hint over the home screen.
            guard !Task.isCancelled else { return }
            var s = HintSession(answer: answer)
            let first = s.start()
            session = s
            question = ""
            say(first.text)
        } catch {
            Speaker.shared.stopWaitingTone()
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            // Said aloud as well: the user may not be looking at the screen while waiting.
            Speaker.shared.say(error.localizedDescription)
        }
    }
}
