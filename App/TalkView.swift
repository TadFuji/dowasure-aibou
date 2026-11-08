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
    /// A calm note (not a warning) when the words were saved but the summary could not be made yet.
    @State private var note: String?
    @State private var voice = VoiceInput()
    @State private var started = false
    /// The screen is being left: words still heard are saved without speaking over the home screen.
    @State private var leaving = false
    /// From opening the screen until the microphone starts (the prompt is being said).
    @State private var waitingToListen = false
    /// Transcript before the last item, so a mistaken item can be taken back.
    @State private var undoTranscript: String?
    /// Transcript just before "いまのを取り消す", so a mistaken undo can be put back (final review, 2026-11-08).
    @State private var redoTranscript: String?

    /// UI tests run without speech output or microphone.
    private let voiceEnabled = !ProcessInfo.processInfo.arguments.contains("-uitest-no-voice")

    var body: some View {
        // Top half: only things to read. Bottom half: every button, within reach of the right thumb (藤川さん, 2026-11-07).
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(lastConfirmation ?? Self.prompt)
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aiQuestion")

                MicStatus(voice: voice, waiting: waitingToListen)
                if let errorMessage {
                    WarningText(text: errorMessage)
                }
                if let note {
                    Label(note, systemImage: "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(.primary) // not .secondary: 3.4:1 on white is below 4.5:1 (final review, 2026-11-08)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("saveNote")
                }

                if !savedToday.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日覚えたこと").font(.title2.bold())
                        ForEach(Array(savedToday.enumerated()), id: \.offset) { _, line in
                            // "16時05分、にんじんを買う" on the screen too, not "[16:05] …": brackets and a colon are
                            // hard to read (elder-user-reviewer, 2026-11-07), and VoiceOver reads it the same way.
                            Text(Self.spokenLine(line)).font(.title2)
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
        .elderScreen("覚えておくこと") {
            // "もう一度きく" and "いまのを取り消す" side by side, so the bottom area stays short.
            if (lastConfirmation != nil && voiceEnabled) || undoTranscript != nil || redoTranscript != nil {
                HStack(spacing: 12) {
                    if let lastConfirmation, voiceEnabled {
                        // Stops listening first: speaking takes the audio away from the microphone, which
                        // would then look as if it listens but hear nothing (ios-reviewer, 2026-11-07).
                        RepeatButton(text: lastConfirmation) {
                            waitingToListen = false
                            voice.cancel()
                            Speaker.shared.say(lastConfirmation)
                        }
                    }
                    if undoTranscript != nil {
                        Button {
                            Task { await undoLast() }
                        } label: {
                            Label("いまのを取り消す", systemImage: "arrow.uturn.backward")
                                .font(.title2.bold())
                                .wrapsForLargeText()
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("undoButton")
                    }
                    if redoTranscript != nil {
                        // The undo itself can be undone: pressed by mistake, the words are not lost.
                        Button {
                            Task { await redoLast() }
                        } label: {
                            Label("取り消しをやめる", systemImage: "arrow.uturn.forward")
                                .font(.title2.bold())
                                .wrapsForLargeText()
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("redoButton")
                    }
                }
            }
            if voiceEnabled {
                MicButton(voice: voice, idleTitle: lastConfirmation == nil ? "声で話す" : "ほかにも話す",
                          waitingToListen: waitingToListen, onCancelWaiting: cancelWaiting) { spoken in
                    Task { await rememberSpoken(spoken) }
                }
            }
            // The field and a full-width button below it: a small text button beside the field was hard to hit.
            TextField("文字で書く（例：4時に歯医者）", text: $typed, axis: .vertical)
                .font(.title2)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("answerInput")
            if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    let text = typed
                    typed = ""
                    // Saving failed: put the words back, so they need not be typed again (ios-reviewer, 2026-11-07).
                    Task { if !(await remember(text)), typed.isEmpty { typed = text } }
                } label: {
                    Label("覚える", systemImage: "checkmark")
                        .font(.title2.bold())
                        .wrapsForLargeText()
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("sendAnswer")
            }
        }
        .task {
            guard !started else { return }
            started = true
            loadToday()
            if voiceEnabled {
                waitingToListen = true
                await Speaker.shared.sayAndWait(Self.prompt)
                // Left the screen during the prompt, or "話し終わった" was pressed: do nothing.
                guard !Task.isCancelled, waitingToListen, !voice.isListening else {
                    waitingToListen = false
                    return
                }
                await voice.start { spoken in Task { await rememberSpoken(spoken) } }
                waitingToListen = false
            }
        }
        .onDisappear {
            waitingToListen = false
            // Words heard so far are still saved, but quietly: before this, the confirmation and the
            // waiting tone started on the home screen (ios-reviewer, 2026-11-07).
            leaving = true
            voice.stop()
            Speaker.shared.stopEverything()
        }
    }

    /// "話し終わった" before the microphone started: stop the prompt and do not listen.
    private func cancelWaiting() {
        waitingToListen = false
        Speaker.shared.stop()
        voice.cancel()
    }

    /// "[16:05] にんじんを買う" → "16時05分、にんじんを買う" for the screen and VoiceOver.
    static func spokenLine(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let time = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard time.count == 2 else { return line }
        return "\(time[0])時\(time[1])分、\(rest)"
    }

    /// Takes back the last saved item (for mis-heard words), then refreshes the summary.
    private func undoLast() async {
        guard let previous = undoTranscript else { return }
        undoTranscript = nil
        let today = DayCalendar().key(for: Date())
        let current = RecordStore.day(today, in: context)?.record
        let extraction = current?.extraction ?? .empty
        try? RecordStore.save(DayRecord(date: today, transcript: previous, extraction: extraction), in: context)
        redoTranscript = current?.transcript
        savedToday = previous.split(separator: "\n").map(String.init)
        lastConfirmation = "取り消しました。"
        if voiceEnabled { Speaker.shared.say("取り消しました。") }
        await refreshSummary(previous, on: today)
    }

    /// Puts back what "いまのを取り消す" took away.
    private func redoLast() async {
        guard let restored = redoTranscript else { return }
        redoTranscript = nil
        let today = DayCalendar().key(for: Date())
        let current = RecordStore.day(today, in: context)?.record
        try? RecordStore.save(DayRecord(date: today, transcript: restored,
                                        extraction: current?.extraction ?? .empty), in: context)
        undoTranscript = current?.transcript ?? ""
        savedToday = restored.split(separator: "\n").map(String.init)
        lastConfirmation = "元に戻しました。"
        if voiceEnabled { Speaker.shared.say("元に戻しました。") }
        await refreshSummary(restored, on: today)
    }

    /// Makes the summary again for this transcript, unless something new was added meanwhile.
    private func refreshSummary(_ transcript: String, on today: String) async {
        let previous = transcript
        guard !previous.isEmpty else { return }
        if let refreshed = try? await Recorder(client: ClaudeClient(apiKey: APIKeyStore.load())).extract(transcript: previous),
           RecordStore.day(today, in: context)?.record?.transcript == previous {
            try? RecordStore.save(DayRecord(date: today, transcript: previous, extraction: refreshed), in: context)
        }
    }

    private func loadToday() {
        let today = DayCalendar().key(for: Date())
        let transcript = RecordStore.day(today, in: context)?.record?.transcript ?? ""
        savedToday = transcript.split(separator: "\n").map(String.init)
    }

    /// Saves the words at once (so nothing is lost), repeats them back, then updates the summary in the background.
    /// Spoken words that could not be saved are put in the text field, so they need not be said again
    /// (ios-reviewer, second look, 2026-11-07).
    private func rememberSpoken(_ spoken: String) async {
        if !(await remember(spoken)), typed.isEmpty, !leaving {
            typed = spoken
            let message = "記録できませんでした。話した言葉を下の欄に残しました。「覚える」を押してください。"
            errorMessage = message
            // Said aloud too, so the words on the screen and the voice tell the same thing.
            if voiceEnabled { Speaker.shared.say(message) }
        }
    }

    /// Returns false only when the words could not be saved.
    @discardableResult
    private func remember(_ text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return true }
        let speaks = voiceEnabled && !leaving
        // Typed during the opening words: do not open the microphone over the confirmation.
        waitingToListen = false
        voice.stop()
        errorMessage = nil
        note = nil
        let today = DayCalendar().key(for: Date())
        let existing = RecordStore.day(today, in: context)?.record
        let transcript = MemoLog.appending(words, at: Date(), to: existing?.transcript ?? "")
        do {
            try RecordStore.save(DayRecord(date: today, transcript: transcript,
                                           extraction: existing?.extraction ?? .empty), in: context)
        } catch {
            errorMessage = "記録できませんでした。もう一度お試しください。"
            if speaks { Speaker.shared.say("記録できませんでした。もう一度お試しください。") }
            return false
        }
        savedToday = transcript.split(separator: "\n").map(String.init)
        undoTranscript = existing?.transcript ?? ""
        redoTranscript = nil
        let confirmation = MemoLog.confirmation(for: words)
        lastConfirmation = confirmation
        if speaks {
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
            // The words are already saved (that is what matters); the summary is made again next time.
            // Shown quietly, not as a red warning, so it does not look as if saving failed.
            if case ClaudeError.missingAPIKey = error {
                note = "記録しました。はじめの準備がまだなので、話した言葉のまま残しています。"
            } else {
                note = "記録しました。まとめは、次に話したときに作り直します。"
            }
        }
        return true
    }
}
