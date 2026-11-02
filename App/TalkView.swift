import SwiftUI
import SwiftData
import DowasureCore

/// Evening conversation: the AI asks one question at a time by voice, the user answers by voice
/// (or by typing), and at the end the conversation is summarized and saved as today's record.
struct TalkView: View {
    enum Phase: Equatable {
        case speaking, listening, thinking, saving, finished
    }

    @Environment(\.modelContext) private var context
    @State private var turns: [InterviewTurn] = []
    @State private var phase: Phase = .speaking
    @State private var typed = ""
    @State private var saved: Extraction?
    @State private var errorMessage: String?
    @State private var voice = VoiceInput()
    @State private var started = false

    /// UI tests run without speech output or microphone.
    private let voiceEnabled = !ProcessInfo.processInfo.arguments.contains("-uitest-no-voice")

    private var currentQuestion: String {
        turns.last(where: { $0.speaker == .ai })?.text ?? Interviewer.firstQuestion
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(currentQuestion)
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("aiQuestion")

                switch phase {
                case .thinking:
                    ProgressView("考えています…").font(.title3)
                case .saving:
                    ProgressView("まとめています…").font(.title3)
                case .finished:
                    if let saved { SavedSummary(extraction: saved) }
                default:
                    answerControls
                }

                if let errorMessage {
                    Text(errorMessage).font(.title3).foregroundStyle(.red)
                }

                if !turns.isEmpty && phase != .finished && phase != .saving {
                    Button("今日はここまでにする") {
                        Task { await finish(say: Interviewer.closing) }
                    }
                    .font(.title3)
                    .accessibilityIdentifier("endButton")
                }
            }
            .padding(24)
        }
        .navigationTitle("今日のこと")
        .task {
            guard !started else { return }
            started = true
            turns = [InterviewTurn(.ai, Interviewer.firstQuestion)]
            await speakThenListen(Interviewer.firstQuestion)
        }
        .onDisappear {
            voice.stop()
            Speaker.shared.stop()
        }
    }

    @ViewBuilder private var answerControls: some View {
        if voiceEnabled {
            MicButton(voice: voice) { spoken in
                Task { await handleAnswer(spoken) }
            }
        }
        HStack {
            TextField("文字で答える", text: $typed, axis: .vertical)
                .font(.title3)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("answerInput")
            Button("送る") {
                let text = typed
                typed = ""
                Task { await handleAnswer(text) }
            }
            .font(.title3.bold())
            .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sendAnswer")
        }
    }

    private func speakThenListen(_ text: String) async {
        phase = .speaking
        if voiceEnabled {
            await Speaker.shared.sayAndWait(text)
        }
        guard phase == .speaking else { return }
        phase = .listening
        if voiceEnabled {
            await voice.start { spoken in
                Task { await handleAnswer(spoken) }
            }
        }
    }

    private func handleAnswer(_ text: String) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, phase == .listening || phase == .speaking else { return }
        voice.stop()
        Speaker.shared.stop()
        errorMessage = nil
        turns.append(InterviewTurn(.user, answer))
        phase = .thinking
        do {
            let step = try await Interviewer(client: ClaudeClient(apiKey: APIKeyStore.load())).next(after: turns)
            if step.done {
                await finish(say: step.say)
            } else {
                turns.append(InterviewTurn(.ai, step.say))
                await speakThenListen(step.say)
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .listening
        }
    }

    /// Ends the conversation and saves today's record (appending to an earlier talk today, if any).
    private func finish(say closing: String) async {
        voice.stop()
        turns.append(InterviewTurn(.ai, closing))
        phase = .saving
        if voiceEnabled { Speaker.shared.say(closing) }
        guard turns.contains(where: { $0.speaker == .user }) else {
            phase = .finished
            return
        }
        let dc = DayCalendar()
        let today = dc.key(for: Date())
        let previous = RecordStore.day(today, in: context)?.record?.transcript ?? ""
        let talk = Interviewer.transcript(of: turns)
        let transcript = previous.isEmpty ? talk : previous + "\n" + talk
        do {
            let extraction = try await Recorder(client: ClaudeClient(apiKey: APIKeyStore.load())).extract(transcript: transcript)
            try RecordStore.save(DayRecord(date: today, transcript: transcript, extraction: extraction), in: context)
            saved = extraction
            phase = .finished
        } catch {
            errorMessage = error.localizedDescription
            phase = .listening
        }
    }
}

struct SavedSummary: View {
    let extraction: Extraction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("記録しました").font(.title2.bold())
            Text(extraction.summary).font(.title3)
            if !extraction.people.isEmpty {
                Text("会った人：" + extraction.people.map(\.name).joined(separator: "、")).font(.title3)
            }
            if !extraction.promises.isEmpty {
                Text("約束：" + extraction.promises.map { [$0.what, $0.due].filter { !$0.isEmpty }.joined(separator: "（") + ($0.due.isEmpty ? "" : "）") }.joined(separator: "、")).font(.title3)
            }
            if !extraction.places.isEmpty {
                Text("場所：" + extraction.places.map(\.name).joined(separator: "、")).font(.title3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("savedSummary")
    }
}
