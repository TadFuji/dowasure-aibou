import Foundation

/// One day's record. Stored on the device only.
public struct DayRecord: Codable, Sendable, Equatable, Identifiable {
    /// Local calendar date in "yyyy-MM-dd" form. Also the identity of the record.
    public var date: String
    public var transcript: String
    public var extraction: Extraction

    public var id: String { date }

    public init(date: String, transcript: String, extraction: Extraction) {
        self.date = date
        self.transcript = transcript
        self.extraction = extraction
    }
}

/// What the model pulls out of a day's conversation.
/// Field names match the JSON schema sent to the API.
public struct Extraction: Codable, Sendable, Equatable {
    public struct Person: Codable, Sendable, Equatable {
        public var name: String
        public var relation: String
        public var note: String
        public init(name: String, relation: String = "", note: String = "") {
            self.name = name; self.relation = relation; self.note = note
        }
    }
    public struct Promise: Codable, Sendable, Equatable {
        public var what: String
        public var with: String
        public var due: String
        public init(what: String, with: String = "", due: String = "") {
            self.what = what; self.with = with; self.due = due
        }
    }
    public struct Place: Codable, Sendable, Equatable {
        public var name: String
        public var note: String
        public init(name: String, note: String = "") {
            self.name = name; self.note = note
        }
    }
    public struct Number: Codable, Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) {
            self.label = label; self.value = value
        }
    }

    public var summary: String
    public var people: [Person]
    public var promises: [Promise]
    public var places: [Place]
    public var numbers: [Number]
    public var events: [String]

    public init(summary: String, people: [Person] = [], promises: [Promise] = [],
                places: [Place] = [], numbers: [Number] = [], events: [String] = []) {
        self.summary = summary; self.people = people; self.promises = promises
        self.places = places; self.numbers = numbers; self.events = events
    }

    public static let empty = Extraction(summary: "")
}

public enum Confidence: String, Codable, Sendable {
    case high, medium, low
}

/// Raw answer as returned by the model (before verification).
public struct ModelAnswer: Codable, Sendable, Equatable {
    public var found: Bool
    public var answer: String
    public var evidenceDates: [String]
    public var confidence: Confidence
    public var followupQuestion: String
    /// Hints that help the user recall by themselves, weakest first. Must not contain the answer.
    public var hints: [String]
    /// Words that mean the user remembered correctly (e.g. "森田", "もりた").
    public var answerKeywords: [String]

    enum CodingKeys: String, CodingKey {
        case found, answer, confidence, hints
        case evidenceDates = "evidence_dates"
        case followupQuestion = "followup_question"
        case answerKeywords = "answer_keywords"
    }

    public init(found: Bool, answer: String, evidenceDates: [String], confidence: Confidence, followupQuestion: String,
                hints: [String] = [], answerKeywords: [String] = []) {
        self.found = found; self.answer = answer; self.evidenceDates = evidenceDates
        self.confidence = confidence; self.followupQuestion = followupQuestion
        self.hints = hints; self.answerKeywords = answerKeywords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = try c.decode(Bool.self, forKey: .found)
        answer = try c.decode(String.self, forKey: .answer)
        evidenceDates = try c.decode([String].self, forKey: .evidenceDates)
        confidence = try c.decode(Confidence.self, forKey: .confidence)
        followupQuestion = try c.decode(String.self, forKey: .followupQuestion)
        hints = try c.decodeIfPresent([String].self, forKey: .hints) ?? []
        answerKeywords = try c.decodeIfPresent([String].self, forKey: .answerKeywords) ?? []
    }
}

/// Answer shown and spoken to the user. Evidence dates are attached by code,
/// only from records that were actually given to the model.
public struct VerifiedAnswer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case found(evidenceDates: [String])
        case notFound
    }
    public var kind: Kind
    public var answer: String
    public var confidence: Confidence
    public var followupQuestion: String
    /// Text for the screen and for speech, e.g. "10月8日の記録より：山田さんです。"
    public var displayText: String
    /// Hints shown before the answer (empty when nothing was found).
    public var hints: [String] = []
    public var answerKeywords: [String] = []
}
