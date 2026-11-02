import SwiftUI
import SwiftData
import DowasureCore

/// Records today's events. Text input for now; voice comes next.
struct TalkView: View {
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var isWorking = false
    @State private var saved: Extraction?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("今日は、どなたかと会ったり、話したりしましたか？")
                    .font(.title2.bold())
                TextEditor(text: $text)
                    .font(.title3)
                    .frame(minHeight: 200)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary))
                    .accessibilityIdentifier("talkInput")
                BigButton(title: isWorking ? "まとめています…" : "記録する", systemImage: "square.and.arrow.down", color: .indigo) {
                    Task { await save() }
                }
                .disabled(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveButton")

                if let errorMessage {
                    Text(errorMessage).font(.title3).foregroundStyle(.red)
                }
                if let saved {
                    SavedSummary(extraction: saved)
                }
            }
            .padding(24)
        }
        .navigationTitle("今日のこと")
    }

    private func save() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let dc = DayCalendar()
        let today = dc.key(for: Date())
        // Append to today's transcript so several talks in one day become one record.
        let previous = RecordStore.day(today, in: context)?.record?.transcript ?? ""
        let transcript = previous.isEmpty ? text : previous + "\n" + text
        do {
            let extraction = try await Recorder(client: ClaudeClient(apiKey: APIKeyStore.load())).extract(transcript: transcript)
            try RecordStore.save(DayRecord(date: today, transcript: transcript, extraction: extraction), in: context)
            saved = extraction
            text = ""
        } catch {
            errorMessage = error.localizedDescription
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
