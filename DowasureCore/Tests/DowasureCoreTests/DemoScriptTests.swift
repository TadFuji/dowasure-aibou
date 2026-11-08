import Foundation
import Testing
@testable import DowasureCore

/// The demo video asks this exact question about the fictional 森田さん record (3 days ago).
@Suite struct DemoScriptTests {
    @Test func demoQuestionFindsTheMoritaDay() {
        let today = Date()
        let records = SampleData.records(today: today)
        let retriever = Retriever()
        let q = "駅前の喫茶店で会った、元同僚の名前、何だっけ"
        let picked = retriever.candidates(for: q, in: records, today: today)
        let moritaKey = records.first { $0.extraction.summary.contains("森田") }!.date
        print("picked:", picked.map(\.date), "range:", String(describing: retriever.dateRange(in: q, today: today)))
        #expect(picked.contains { $0.date == moritaKey })
    }
}

/// Live check against the real API; runs only when DOWASURE_LIVE_KEY_FILE points at a key file.
@Suite struct DemoScriptLiveTests {
    @Test func demoQuestionIsAnsweredWithHints() async throws {
        guard let path = ProcessInfo.processInfo.environment["DOWASURE_LIVE_KEY_FILE"],
              let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        let today = Date()
        let answerer = Answerer(client: ClaudeClient(apiKey: key))
        let a = try await answerer.answer("駅前の喫茶店で会った、元同僚の名前、何だっけ",
                                          records: SampleData.records(today: today), today: today)
        print("kind:", a.kind, "text:", a.displayText, "hints:", a.hints)
        if case .found = a.kind {} else { Issue.record("not found: \(a.displayText)") }
    }
}
