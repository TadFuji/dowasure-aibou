import Foundation

/// One line of the evening conversation.
public struct InterviewTurn: Sendable, Equatable {
    public enum Speaker: Sendable, Equatable { case ai, user }
    public var speaker: Speaker
    public var text: String
    public init(_ speaker: Speaker, _ text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// The model's next move in the evening conversation.
public struct InterviewStep: Codable, Sendable, Equatable {
    public var say: String
    public var done: Bool
    public init(say: String, done: Bool) {
        self.say = say
        self.done = done
    }
}

/// Runs the evening "what happened today" conversation (F1).
/// The first question and the hard limits are decided in code; the model only picks the next question.
public struct Interviewer: Sendable {
    public static let firstQuestion = "今日は、どなたかと会ったり、話したりしましたか？"
    public static let closing = "今日はここまでにしますね。お話ししてくださって、ありがとうございました。"

    let client: ClaudeClient
    /// Upper limit of AI questions, including the first one. Keeps the talk within about five minutes.
    public var maxQuestions: Int

    public init(client: ClaudeClient, maxQuestions: Int = 7) {
        self.client = client
        self.maxQuestions = maxQuestions
    }

    /// Decides what the AI says after the user's latest answer.
    public func next(after turns: [InterviewTurn], today: Date = Date(),
                     dayCalendar: DayCalendar = DayCalendar()) async throws -> InterviewStep {
        let asked = turns.filter { $0.speaker == .ai }.count
        if asked >= maxQuestions {
            return InterviewStep(say: Self.closing, done: true)
        }
        let step = try await client.structured(
            InterviewStep.self, model: .haiku,
            system: Prompts.interviewSystem,
            messages: Self.messages(for: turns, today: today, dayCalendar: dayCalendar),
            schema: Prompts.interviewSchema).0
        let say = step.say.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.done || say.isEmpty {
            return InterviewStep(say: say.isEmpty ? Self.closing : say, done: true)
        }
        return InterviewStep(say: say, done: false)
    }

    /// Conversation as API messages: a fixed opening user turn, then alternating AI / user lines.
    static func messages(for turns: [InterviewTurn], today: Date, dayCalendar: DayCalendar) -> [ClaudeClient.Message] {
        let label = dayCalendar.spokenLabel(for: dayCalendar.key(for: today))
        var messages: [ClaudeClient.Message] = [.user("（今日は\(label)です。夜の聞き取りを始めてください。）")]
        for turn in turns {
            let message: ClaudeClient.Message = turn.speaker == .ai ? .assistant(turn.text) : .user(turn.text)
            // Merge consecutive lines from the same side so roles keep alternating.
            if let last = messages.last, last.role == message.role {
                messages[messages.count - 1] = ClaudeClient.Message(role: last.role, content: last.content + "\n" + message.content)
            } else {
                messages.append(message)
            }
        }
        return messages
    }

    /// Text handed to the extraction step.
    public static func transcript(of turns: [InterviewTurn]) -> String {
        turns.map { ($0.speaker == .ai ? "聞き手: " : "本人: ") + $0.text }.joined(separator: "\n")
    }
}
