import Foundation

/// Turns a day's conversation into a structured record (F3).
public struct Recorder: Sendable {
    let client: ClaudeClient

    public init(client: ClaudeClient) { self.client = client }

    public func extract(transcript: String) async throws -> Extraction {
        let (extraction, _) = try await client.structured(
            Extraction.self, model: .haiku,
            system: Prompts.extractionSystem,
            user: transcript,
            schema: Prompts.extractionSchema)
        return extraction
    }
}

/// Answers a "what was it again?" question from the user's own records (F4).
public struct Answerer: Sendable {
    let client: ClaudeClient
    public var retriever: Retriever
    /// How much the model thinks ("low", "medium", ...). nil keeps the model's default (medium on Haiku 5.5).
    public var effort: String?

    public init(client: ClaudeClient, retriever: Retriever = Retriever(), effort: String? = nil) {
        self.client = client
        self.retriever = retriever
        self.effort = effort
    }

    public func answer(_ question: String, records: [DayRecord], today: Date = Date()) async throws -> VerifiedAnswer {
        let candidates = retriever.candidates(for: question, in: records, today: today)
        let dc = retriever.dayCalendar
        guard !candidates.isEmpty else {
            return Self.verify(ModelAnswer(found: false, answer: "", evidenceDates: [], confidence: .low,
                                           followupQuestion: "いつ頃のことか、覚えていますか？"),
                               candidates: [], dayCalendar: dc)
        }
        let user = """
        今日は \(dc.key(for: today)) です。

        \(Prompts.renderRecords(candidates))

        質問: \(question)
        """
        let (raw, _) = try await client.structured(
            ModelAnswer.self, model: .haiku,
            system: Prompts.answerSystem,
            user: user,
            schema: Prompts.answerSchema,
            effort: effort)
        return Self.verify(raw, candidates: candidates, dayCalendar: dc)
    }

    /// After "not found, when was it?", a short reply such as "先週" belongs to the earlier question,
    /// so both are searched together. A longer reply is taken as a new question.
    public static func followUpQuestion(previous: String?, reply: String) -> String {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previous = previous?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty,
              reply.count <= maxFollowUpLength else { return reply }
        return "\(previous)（\(reply)）"
    }

    /// Ending of the fallback hint made in code from the date (not by the model).
    public static let dateHintSuffix = "に覚えておいたことです。"

    /// Replies up to this many characters are treated as an answer to the follow-up question.
    public static let maxFollowUpLength = 15

    /// Keeps only evidence dates that belong to records actually sent to the model,
    /// and composes the date part of the reply in code (not by the model).
    public static func verify(_ raw: ModelAnswer, candidates: [DayRecord], dayCalendar: DayCalendar) -> VerifiedAnswer {
        let allowed = Set(candidates.map(\.date))
        let evidence = Array(Set(raw.evidenceDates.filter { allowed.contains($0) })).sorted()
        let followup = raw.followupQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.found && !evidence.isEmpty && !answer.isEmpty {
            let labels = evidence.map(dayCalendar.spokenLabel(for:)).joined(separator: "と")
            var text = "\(labels)の記録より：\(answer)"
            if !followup.isEmpty { text += "\n\(followup)" }
            let keywords = raw.answerKeywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // A hint that gives away the answer is dropped; the user should get the chance to recall.
            var hints = raw.hints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !HintSession.matches($0, keywords: keywords) }
            // If every hint was dropped, give the date as a first cue rather than the answer at once.
            // When the date is itself the answer, that cue would give it away: then there is no safe hint,
            // and HintSession says the answer plainly (not counted as recalled by themselves).
            if hints.isEmpty {
                let dateHint = labels + dateHintSuffix
                if !HintSession.matches(dateHint, keywords: keywords) { hints = [dateHint] }
            }
            return VerifiedAnswer(kind: .found(evidenceDates: evidence), answer: answer,
                                  confidence: raw.confidence, followupQuestion: followup, displayText: text,
                                  hints: hints, answerKeywords: keywords)
        }
        let question = followup.isEmpty ? "いつ頃のことか、覚えていますか？" : followup
        return VerifiedAnswer(kind: .notFound, answer: "", confidence: .low, followupQuestion: question,
                              displayText: "記録には見当たりません。\n\(question)")
    }
}
