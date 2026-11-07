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

/// Fake transport that answers with a list of results in order (an HTTP status or a network error).
final class SequenceTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case status(Int), network(URLError.Code) }
    private var steps: [Step]
    private(set) var calls = 0
    let okBody: String

    init(_ steps: [Step], okBody: String) {
        self.steps = steps
        self.okBody = okBody
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let step: Step = steps.isEmpty ? .status(200) : steps.removeFirst()
        switch step {
        case .network(let code): throw URLError(code)
        case .status(let status):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data((status == 200 ? okBody : "{}").utf8), http)
        }
    }
}

@Suite struct RetryTests {
    let ok = FakeTransport.messages(text: #"{"summary":"散歩した","people":[],"promises":[],"places":[],"numbers":[],"events":[]}"#)

    func extract(_ transport: SequenceTransport) async throws -> Extraction {
        try await Recorder(client: ClaudeClient(apiKey: "k", transport: transport, retryDelay: 0)).extract(transcript: "x")
    }

    @Test func overloadedIsRetriedOnce() async throws {
        let t = SequenceTransport([.status(529), .status(200)], okBody: ok)
        #expect(try await extract(t).summary == "散歩した")
        #expect(t.calls == 2)
    }

    @Test func secondFailureIsReportedNotRetriedAgain() async {
        let t = SequenceTransport([.status(503), .status(503), .status(200)], okBody: ok)
        await #expect(throws: ClaudeError.http(status: 503, body: "{}")) { _ = try await extract(t) }
        #expect(t.calls == 2)
    }

    @Test func wrongKeyIsNotRetried() async {
        let t = SequenceTransport([.status(401)], okBody: ok)
        await #expect(throws: ClaudeError.http(status: 401, body: "{}")) { _ = try await extract(t) }
        #expect(t.calls == 1)
    }

    @Test func droppedConnectionIsRetried() async throws {
        let t = SequenceTransport([.network(.networkConnectionLost), .status(200)], okBody: ok)
        #expect(try await extract(t).summary == "散歩した")
        #expect(t.calls == 2)
    }

    @Test func offlineIsPlainAndNotRetried() async {
        let t = SequenceTransport([.network(.notConnectedToInternet)], okBody: ok)
        await #expect(throws: ClaudeError.offline) { _ = try await extract(t) }
        #expect(t.calls == 1)
    }

    @Test func timeoutIsPlainAndNotRetried() async {
        let t = SequenceTransport([.network(.timedOut)], okBody: ok)
        await #expect(throws: ClaudeError.timedOut) { _ = try await extract(t) }
        #expect(t.calls == 1)
    }

    @Test func messagesAreInPlainWords() {
        let busy = ClaudeError.http(status: 529, body: "").errorDescription ?? ""
        #expect(busy.contains("混み合って"))
        #expect(!busy.contains("529"))
        #expect(!(ClaudeError.http(status: 400, body: "").errorDescription ?? "").contains("400"))
        #expect(ClaudeError.missingAPIKey.errorDescription == "APIキーが設定されていません。設定画面で入力してください。")
    }

    @Test func checkKeyReportsWrongKey() async {
        let client = ClaudeClient(apiKey: "k", transport: FakeTransport(status: 401, body: "{}"))
        #expect(await client.checkKey() == .http(status: 401, body: "{}"))
        let good = ClaudeClient(apiKey: "k", transport: FakeTransport(status: 200, body: "{}"))
        #expect(await good.checkKey() == nil)
    }
}

@Suite struct FollowUpTests {
    @Test func shortReplyJoinsEarlierQuestion() {
        #expect(Answerer.followUpQuestion(previous: "眼鏡の人の名前", reply: " 先週 ") == "眼鏡の人の名前（先週）")
    }

    @Test func longReplyIsANewQuestion() {
        let reply = "孫の誕生日のプレゼントに何を買うと言っていたか"
        #expect(Answerer.followUpQuestion(previous: "眼鏡の人の名前", reply: reply) == reply)
    }

    @Test func noEarlierQuestion() {
        #expect(Answerer.followUpQuestion(previous: nil, reply: "先週") == "先週")
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

@Suite struct VoiceTimingTests {
    @Test func waitsLongerBeforeFirstWords() {
        #expect(VoiceTiming.silenceTimeout(heardSomething: false) >= 15)
        #expect(VoiceTiming.silenceTimeout(heardSomething: true) < VoiceTiming.silenceTimeout(heardSomething: false))
    }
}

@Suite struct CloudVoiceTests {
    @Test func requestCarriesTextVoiceAndKey() async throws {
        let audio = Data("wav".utf8).base64EncodedString()
        let fake = FakeTransport(body: #"{"steps":[{"type":"user_input"},{"type":"model_output","content":[{"type":"audio","data":"\#(audio)"}]}]}"#)
        let data = try await CloudVoice(apiKey: "g-key", transport: fake).synthesize("こんばんは")
        #expect(data == Data("wav".utf8))
        let req = try #require(fake.lastRequest)
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        #expect(req.url?.query == nil)
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(json["model"] as? String == CloudVoice.model)
        let input = (json["input"] as! [[String: Any]])[0]
        let content = (input["content"] as! [[String: Any]])[0]
        #expect(content["text"] as? String == "こんばんは")
        let speech = (json["generation_config"] as! [String: Any])["speech_config"] as! [[String: Any]]
        #expect(speech[0]["voice"] as? String == CloudVoice.defaultVoiceName)
    }

    @Test func missingKeyFailsWithoutNetwork() async {
        let fake = FakeTransport(body: "")
        await #expect(throws: ClaudeError.missingAPIKey) {
            _ = try await CloudVoice(apiKey: "", transport: fake).synthesize("x")
        }
        #expect(fake.lastRequest == nil)
    }

    @Test func httpErrorIsReported() async {
        let fake = FakeTransport(status: 403, body: "{}")
        await #expect(throws: ClaudeError.http(status: 403, body: "{}")) {
            _ = try await CloudVoice(apiKey: "k", transport: fake).synthesize("x")
        }
    }

    @Test func missingAudioIsAnError() async {
        let fake = FakeTransport(body: #"{"steps":[{"type":"model_output","content":[{"type":"text"}]}]}"#)
        await #expect(throws: ClaudeError.decoding("tts audio missing")) {
            _ = try await CloudVoice(apiKey: "k", transport: fake).synthesize("x")
        }
    }
}

@Suite struct CloudVoiceStreamTests {
    @Test func parsesAudioDeltaLines() {
        let b64 = Data([1, 2, 3, 4]).base64EncodedString()
        #expect(CloudVoice.audioChunk(fromSSELine: #"data: {"index":0,"delta":{"data":"\#(b64)"},"event_type":"step.delta"}"#) == Data([1, 2, 3, 4]))
    }

    @Test func ignoresOtherLines() {
        #expect(CloudVoice.audioChunk(fromSSELine: "event: step.delta") == nil)
        #expect(CloudVoice.audioChunk(fromSSELine: #"data: {"event_type":"interaction.created"}"#) == nil)
        #expect(CloudVoice.audioChunk(fromSSELine: "") == nil)
    }
}

@Suite struct HintSessionTests {
    func found(hints: [String] = ["駅前の喫茶店で会った方です。", "お名前は『も』で始まります。"]) -> VerifiedAnswer {
        let raw = ModelAnswer(found: true, answer: "森田さんです。", evidenceDates: ["2026-10-08"], confidence: .high,
                              followupQuestion: "", hints: hints, answerKeywords: ["森田", "もりた"])
        return Answerer.verify(raw, candidates: [record("2026-10-08", summary: "駅前で森田さんに会った")], dayCalendar: tokyo)
    }

    @Test func startsWithHintNotAnswer() {
        var s = HintSession(answer: found())
        let r = s.start()
        #expect(!r.revealed)
        #expect(r.text.contains("駅前の喫茶店"))
        #expect(!r.text.contains("森田"))
    }

    @Test func correctGuessInKanaIsAccepted() {
        var s = HintSession(answer: found())
        _ = s.start()
        let r = s.respond(to: "もりたさん？")
        #expect(r.revealed)
        #expect(r.text.hasPrefix("そうです！"))
        #expect(r.text.contains("10月8日の記録より"))
        #expect(r.recalledByThemselves)
        #expect(s.hintsGiven == 1)
    }

    @Test func revealedAnswerIsNotCountedAsRecalled() {
        var s = HintSession(answer: found())
        _ = s.start()
        #expect(!s.respond(to: "答えを教えて").recalledByThemselves)
        var t = HintSession(answer: found())
        _ = t.start()
        #expect(!t.reveal().recalledByThemselves)
        #expect(!t.respond(to: "森田さん").recalledByThemselves)  // already revealed
    }

    @Test func wrongGuessGivesNextHintThenOffersAnswer() {
        var s = HintSession(answer: found())
        _ = s.start()
        let r1 = s.respond(to: "山田さん")
        #expect(!r1.revealed && r1.text.contains("『も』"))
        let r2 = s.respond(to: "田中さん")
        #expect(!r2.revealed && r2.text.contains("答えを教えて"))
    }

    @Test func askingForAnswerReveals() {
        var s = HintSession(answer: found())
        _ = s.start()
        let r = s.respond(to: "わからないので答えを教えて")
        #expect(r.revealed && r.text == "10月8日の記録より：森田さんです。")
    }

    @Test func hintThatLeaksAnswerIsDropped() {
        let a = found(hints: ["森田さんという方です。", "駅前でお会いしました。"])
        #expect(a.hints == ["駅前でお会いしました。"])
    }

    @Test func wrongGuessSaysWhatWasHeard() {
        var s = HintSession(answer: found())
        _ = s.start()
        let r = s.respond(to: "守田さん")
        #expect(!r.revealed)
        #expect(r.text.hasPrefix("「守田さん」と聞こえました。"))
    }

    @Test func allHintsLeakingLeavesADateHint() {
        let a = found(hints: ["森田さんという方です。"])
        #expect(a.hints == ["10月8日" + Answerer.dateHintSuffix])
        var s = HintSession(answer: a)
        let r = s.start()
        #expect(!r.revealed && r.text.contains("10月8日"))
    }

    @Test func oneLetterKeywordMustBeSaidAlone() {
        #expect(HintSession.isCorrectGuess("森", keywords: ["森"]))
        #expect(!HintSession.isCorrectGuess("森本さん", keywords: ["森"]))
        #expect(HintSession.isCorrectGuess("森田さんです", keywords: ["森田"]))
    }

    @Test func notFoundSaysSoImmediately() {
        let raw = ModelAnswer(found: false, answer: "", evidenceDates: [], confidence: .low, followupQuestion: "どこで会いましたか？")
        var s = HintSession(answer: Answerer.verify(raw, candidates: [], dayCalendar: tokyo))
        #expect(s.start().text.hasPrefix("記録には見当たりません。"))
    }
}

@Suite struct MemoLogTests {
    @Test func linesCarryTimeAndAppend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let d = tokyo.date(from: "2026-11-03")!.addingTimeInterval(16 * 3600 + 5 * 60)
        let t = MemoLog.appending("にんじんを買う", at: d, to: "[9:00] 薬局に寄る", calendar: cal)
        #expect(t == "[9:00] 薬局に寄る\n[16:05] にんじんを買う")
        #expect(MemoLog.confirmation(for: " にんじんを買う ") == "「にんじんを買う」ですね。覚えました。")
    }
}

@Suite struct RecallLogTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T06:00:00Z")!

    @Test func countsOnlyTheLastSevenDays() {
        var log = RecallLog()
        log.add(at: now.addingTimeInterval(-3600), hintsUsed: 1)
        log.add(at: now.addingTimeInterval(-5 * 86400), hintsUsed: 2)
        log.add(at: now.addingTimeInterval(-10 * 86400), hintsUsed: 1)
        #expect(log.countInLastWeek(now: now, calendar: tokyo.calendar) == 2)
    }

    @Test func homeMessageHidesZero() {
        #expect(RecallLog.homeMessage(weekCount: 0) == nil)
        #expect(RecallLog.homeMessage(weekCount: 3) == "この1週間で、ご自分で3回思い出せました。")
    }

    @Test func keepsAtMostMaxEntriesAndSurvivesRoundTrip() {
        var log = RecallLog()
        for i in 0..<(RecallLog.maxEntries + 5) { log.add(at: now.addingTimeInterval(Double(i)), hintsUsed: 0) }
        #expect(log.entries.count == RecallLog.maxEntries)
        #expect(log.entries.allSatisfy { $0.hintsUsed == 1 })
        #expect(RecallLog.decoded(from: log.encoded()) == log)
        #expect(RecallLog.decoded(from: Data("broken".utf8)) == RecallLog())
    }
}
