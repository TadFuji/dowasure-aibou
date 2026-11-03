import SwiftUI
import SwiftData
import DowasureCore

/// "Things to remember": the app invites the user to say anything they do not want to forget
/// (at any time of day), repeats it back, and adds it to today's record.
struct TalkView: View {
    static let prompt = "覚えておきたいことを、話してください。"

    @Environment(\.modelContext) private var context
    @State private var typed = ""
    @State private var savedToday: [String] = []
    @State private var lastConfirmation: String?
    @State private var errorMessage: String?
    @State private var voice = VoiceInput()
    @State private var started = false

    /// UI tests run without speech output or microphone.
    private let voiceEnabled = !ProcessInfo.processInfo.arguments.contains("-uitest-no-voice")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(lastConfirmation ?? Self.prompt)
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("aiQuestion")

                if voiceEnabled {
                    MicButton(voice: voice, idleTitle: lastConfirmation == nil ? "声で話す" : "ほかにも話す") { spoken in
                        Task { await remember(spoken) }
                    }
                }
                HStack {
                    TextField("文字で書く（例：4時に歯医者）", text: $typed, axis: .vertical)
                        .font(.title2)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("answerInput")
                    Button("覚える") {
                        let text = typed
                        typed = ""
                        Task { await remember(text) }
                    }
                    .font(.title2.bold())
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("sendAnswer")
                }

                if let errorMessage {
                    Text(errorMessage).font(.title2).foregroundStyle(.red)
                }

                if !savedToday.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日覚えたこと").font(.title2.bold())
                        ForEach(Array(savedToday.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.title2)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("savedSummary")
                }
            }
            .padding(24)
        }
        .elderScreen("覚えておくこと")
        .task {
            guard !started else { return }
            started = true
            loadToday()
            if voiceEnabled {
                await Speaker.shared.sayAndWait(Self.prompt)
                await voice.start { spoken in Task { await remember(spoken) } }
            }
        }
        .onDisappear {
            voice.stop()
            Speaker.shared.stop()
        }
    }

    private func loadToday() {
        let today = DayCalendar().key(for: Date())
        let transcript = RecordStore.day(today, in: context)?.record?.transcript ?? ""
        savedToday = transcript.split(separator: "\n").map(String.init)
    }

    /// Saves the words at once (so nothing is lost), repeats them back, then updates the summary in the background.
    private func remember(_ text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        voice.stop()
        errorMessage = nil
        let today = DayCalendar().key(for: Date())
        let existing = RecordStore.day(today, in: context)?.record
        let transcript = MemoLog.appending(words, at: Date(), to: existing?.transcript ?? "")
        do {
            try RecordStore.save(DayRecord(date: today, transcript: transcript,
                                           extraction: existing?.extraction ?? .empty), in: context)
        } catch {
            errorMessage = "記録できませんでした。もう一度お試しください。"
            return
        }
        savedToday = transcript.split(separator: "\n").map(String.init)
        let confirmation = MemoLog.confirmation(for: words)
        lastConfirmation = confirmation
        if voiceEnabled {
            Speaker.shared.startWaitingTone()
            Task { await Speaker.shared.sayAndWait(confirmation) }
        }
        do {
            let extraction = try await Recorder(client: ClaudeClient(apiKey: APIKeyStore.load())).extract(transcript: transcript)
            // Only update if nothing new was added meanwhile.
            if RecordStore.day(today, in: context)?.record?.transcript == transcript {
                try RecordStore.save(DayRecord(date: today, transcript: transcript, extraction: extraction), in: context)
            }
        } catch {
            // The words are already saved; the summary is refreshed next time.
            errorMessage = "記録はしました。まとめの作成は次の機会に行います（\(error.localizedDescription)）"
        }
    }
}
