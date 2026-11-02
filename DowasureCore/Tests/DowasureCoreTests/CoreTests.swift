import Foundation
import Testing
@testable import DowasureCore

/// Fake transport that records the request and returns a canned response.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var lastRequest: URLRequest?
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }

    /// Wraps model JSON text into a Messages API response, with a thinking block first.
    static func messages(text: String, stopReason: String = "end_turn") -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return """
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":\(escaped)}],
         "stop_reason":"\(stopReason)","usage":{"input_tokens":10,"output_tokens":5}}
        """
    }
}

let tokyo = DayCalendar(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

func date(_ key: String) -> Date { tokyo.date(from: key)!.addingTimeInterval(12 * 3600) }

func record(_ date: String, summary: String, people: [String] = [], places: [String] = []) -> DayRecord {
    DayRecord(date: date, transcript: "",
              extraction: Extraction(summary: summary,
                                     people: people.map { .init(name: $0) },
                                     places: places.map { .init(name: $0) }))
}

@Suite struct ClaudeClientTests {
    @Test func requestUsesStructuredOutputAndHeaders() async throws {
        let fake = FakeTransport(body: FakeTransport.messages(text: #"{"summary":"散歩した","people":[],"promises":[],"places":[],"numbers":[],"events":[]}"#))
        let client = ClaudeClient(apiKey: "test-key", transport: fake)
        let result = try await Recorder(client: client).extract(transcript: "今日は散歩しました")
        #expect(result.summary == "散歩した")

        let req = try #require(fake.lastRequest)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == ClaudeClient.apiVersion)
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(json["model"] as? String == "claude-haiku-5-5")
        let format = (json["output_config"] as! [String: Any])["format"] as! [String: Any]
        #expect(format["type"] as? String == "json_schema")
        #expect(json["temperature"] == nil)
    }

    @Test func missingKeyFailsBeforeNetwork() async {
        let fake = FakeTransport(body: "")
        let client = ClaudeClient(apiKey: "", transport: fake)
        await #expect(throws: ClaudeError.missingAPIKey) {
            _ = try await Recorder(client: client).extract(transcript: "x")
        }
        #expect(fake.lastRequest == nil)
    }

    @Test func httpErrorIsReported() async {
        let client = ClaudeClient(apiKey: "k", transport: FakeTransport(status: 401, body: "{}"))
        await #expect(throws: ClaudeError.http(status: 401, body: "{}")) {
            _ = try await Recorder(client: client).extract(transcript: "x")
        }
    }

    @Test func refusalIsReported() async {
        let client = ClaudeClient(apiKey: "k", transport: FakeTransport(body: FakeTransport.messages(text: "", stopReason: "refusal")))
        await #expect(throws: ClaudeError.refusal) {
            _ = try await Recorder(client: client).extract(transcript: "x")
        }
    }
}

@Suite struct RetrieverTests {
    let retriever = Retriever(dayCalendar: tokyo)
    let today = date("2026-11-12") // Thursday

    @Test func relativeDays() {
        #expect(retriever.dateRange(in: "昨日会った人", today: today) == "2026-11-11"..."2026-11-11")
        #expect(retriever.dateRange(in: "おとといの約束", today: today) == "2026-11-10"..."2026-11-10")
        #expect(retriever.dateRange(in: "3日前に行った店", today: today) == "2026-11-08"..."2026-11-10")
    }

    @Test func weeksAndMonths() {
        #expect(retriever.dateRange(in: "先週、駅前で会った人", today: today) == "2026-11-02"..."2026-11-08")
        #expect(retriever.dateRange(in: "今週の予定", today: today) == "2026-11-09"..."2026-11-12")
        #expect(retriever.dateRange(in: "先月の話", today: today) == "2026-10-01"..."2026-10-31")
    }

    @Test func explicitDateInFutureMeansLastYear() {
        #expect(retriever.dateRange(in: "10月8日のこと", today: today) == "2026-10-08"..."2026-10-08")
        #expect(retriever.dateRange(in: "12月24日のこと", today: today) == "2025-12-24"..."2025-12-24")
    }

    @Test func noTimeWords() {
        #expect(retriever.dateRange(in: "眼鏡の人の名前", today: today) == nil)
    }

    @Test func rankingPrefersNameAndDateRange() {
        let records = [
            record("2026-11-03", summary: "駅前で眼鏡の男性と会った", people: ["山田さん"], places: ["駅前"]),
            record("2026-11-05", summary: "スーパーで買い物をした", places: ["スーパー"]),
            record("2026-10-20", summary: "駅前で眼鏡の男性と会った", people: ["佐藤さん"]),
        ]
        let top = retriever.candidates(for: "先週、駅前で会った眼鏡の人の名前", in: records, today: today)
        #expect(top.map(\.date) == ["2026-11-03", "2026-11-05"])
    }

    @Test func singleKanjiNounFindsDayInWideRange() {
        var records = (1...20).map { record(String(format: "2026-10-%02d", $0 + 10), summary: "散歩をした") }
        records.append(record("2026-10-02", summary: "庭の柿を十二個とった"))
        let top = retriever.candidates(for: "先月、柿って何個とれたっけ", in: records, today: today)
        #expect(top.first?.date == "2026-10-02")
    }

    @Test func respectsMaxRecords() {
        let records = (1...20).map { record(String(format: "2026-10-%02d", $0), summary: "散歩") }
        #expect(retriever.candidates(for: "散歩", in: records, today: today).count == 7)
    }
}

@Suite struct AnswerVerificationTests {
    let candidates = [record("2026-10-08", summary: "駅前で山田さんに会った", people: ["山田さん"])]

    @Test func dateIsComposedByCode() {
        let raw = ModelAnswer(found: true, answer: "山田さんです。", evidenceDates: ["2026-10-08"], confidence: .high, followupQuestion: "")
        let v = Answerer.verify(raw, candidates: candidates, dayCalendar: tokyo)
        #expect(v.kind == .found(evidenceDates: ["2026-10-08"]))
        #expect(v.displayText == "10月8日の記録より：山田さんです。")
    }

    @Test func evidenceOutsideCandidatesIsRejected() {
        let raw = ModelAnswer(found: true, answer: "田中さんです。", evidenceDates: ["2026-09-01"], confidence: .high, followupQuestion: "")
        let v = Answerer.verify(raw, candidates: candidates, dayCalendar: tokyo)
        #expect(v.kind == .notFound)
        #expect(v.displayText.hasPrefix("記録には見当たりません。"))
    }

    @Test func notFoundKeepsFollowup() {
        let raw = ModelAnswer(found: false, answer: "", evidenceDates: [], confidence: .low, followupQuestion: "どこで会いましたか？")
        let v = Answerer.verify(raw, candidates: candidates, dayCalendar: tokyo)
        #expect(v.displayText == "記録には見当たりません。\nどこで会いましたか？")
    }

    @Test func noRecordsSkipsNetwork() async throws {
        let fake = FakeTransport(body: "")
        let answerer = Answerer(client: ClaudeClient(apiKey: "k", transport: fake), retriever: Retriever(dayCalendar: tokyo))
        let v = try await answerer.answer("昨日の人", records: [], today: date("2026-11-12"))
        #expect(v.kind == .notFound)
        #expect(fake.lastRequest == nil)
    }

    @Test func endToEndWithFakeModel() async throws {
        let text = #"{"found":true,"answer":"山田さんです。","evidence_dates":["2026-10-08"],"confidence":"high","followup_question":""}"#
        let fake = FakeTransport(body: FakeTransport.messages(text: text))
        let answerer = Answerer(client: ClaudeClient(apiKey: "k", transport: fake), retriever: Retriever(dayCalendar: tokyo))
        let v = try await answerer.answer("駅前で会った人", records: candidates, today: date("2026-10-10"))
        #expect(v.displayText == "10月8日の記録より：山田さんです。")
        let body = String(data: fake.lastRequest!.httpBody!, encoding: .utf8)!
        #expect(body.contains("2026-10-08"))
    }
}

@Suite struct InterviewerTests {
    @Test func messagesStartWithUserAndAlternate() {
        let turns = [InterviewTurn(.ai, Interviewer.firstQuestion), InterviewTurn(.user, "山田さんに会いました"),
                     InterviewTurn(.user, "駅前で"), InterviewTurn(.ai, "山田さん、とおっしゃいましたか？")]
        let m = Interviewer.messages(for: turns, today: date("2026-11-03"), dayCalendar: tokyo)
        #expect(m.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(m[0].content.contains("11月3日"))
        #expect(m[2].content == "山田さんに会いました\n駅前で")
    }

    @Test func stopsAtQuestionLimitWithoutNetwork() async throws {
        let fake = FakeTransport(body: "")
        let interviewer = Interviewer(client: ClaudeClient(apiKey: "k", transport: fake), maxQuestions: 2)
        let turns = [InterviewTurn(.ai, "q1"), InterviewTurn(.user, "a1"), InterviewTurn(.ai, "q2"), InterviewTurn(.user, "a2")]
        let step = try await interviewer.next(after: turns, today: date("2026-11-03"), dayCalendar: tokyo)
        #expect(step == InterviewStep(say: Interviewer.closing, done: true))
        #expect(fake.lastRequest == nil)
    }

    @Test func emptySayBecomesClosing() async throws {
        let fake = FakeTransport(body: FakeTransport.messages(text: #"{"say":"","done":false}"#))
        let interviewer = Interviewer(client: ClaudeClient(apiKey: "k", transport: fake))
        let step = try await interviewer.next(after: [InterviewTurn(.ai, "q1"), InterviewTurn(.user, "a1")],
                                              today: date("2026-11-03"), dayCalendar: tokyo)
        #expect(step.done)
        #expect(step.say == Interviewer.closing)
    }

    @Test func transcriptLabelsSpeakers() {
        let t = Interviewer.transcript(of: [InterviewTurn(.ai, "誰かと会いましたか？"), InterviewTurn(.user, "妻と散歩しました")])
        #expect(t == "聞き手: 誰かと会いましたか？\n本人: 妻と散歩しました")
    }
}
