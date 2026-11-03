import Foundation

/// The "recall it yourself" conversation after a question: hints first, the answer only when asked
/// or when the user names it. Runs on the device with no extra AI calls, so replies are instant.
public struct HintSession: Sendable, Equatable {
    public struct Reply: Sendable, Equatable {
        public var text: String
        public var revealed: Bool
    }

    public let answer: VerifiedAnswer
    public private(set) var hintsGiven = 0
    public private(set) var revealed = false

    public init(answer: VerifiedAnswer) {
        self.answer = answer
    }

    /// What to say first.
    public mutating func start() -> Reply {
        guard case .found = answer.kind else {
            revealed = true
            return Reply(text: answer.displayText, revealed: true)
        }
        guard let first = answer.hints.first else {
            return reveal()
        }
        hintsGiven = 1
        return Reply(text: "ヒントです。\(first)\n思い出せたら、言ってみてください。", revealed: false)
    }

    /// Reacts to what the user said (or a button): a guess, "more hint", or "tell me the answer".
    public mutating func respond(to utterance: String) -> Reply {
        if revealed { return Reply(text: answer.displayText, revealed: true) }
        if Self.asksForAnswer(utterance) { return reveal() }
        if Self.matches(utterance, keywords: answer.answerKeywords) {
            revealed = true
            return Reply(text: "そうです！\n\(answer.displayText)", revealed: true)
        }
        let prefix = Self.asksForHint(utterance) ? "" : "うーん、少し違うようです。\n"
        return Reply(text: prefix + nextHintOrOffer(), revealed: false)
    }

    public mutating func moreHint() -> Reply {
        if revealed { return Reply(text: answer.displayText, revealed: true) }
        return Reply(text: nextHintOrOffer(), revealed: false)
    }

    public mutating func reveal() -> Reply {
        revealed = true
        return Reply(text: answer.displayText, revealed: true)
    }

    public var hasMoreHints: Bool { hintsGiven < answer.hints.count }

    private mutating func nextHintOrOffer() -> String {
        if hintsGiven < answer.hints.count {
            let hint = answer.hints[hintsGiven]
            hintsGiven += 1
            return "もう一つヒントです。\(hint)"
        }
        return "ヒントは以上です。「答えを教えて」と言っていただければ、お伝えします。"
    }

    // MARK: Understanding the user's words (on-device, simple and predictable)

    static func asksForAnswer(_ text: String) -> Bool {
        let t = normalize(text)
        return ["答え", "こたえ", "教えて", "おしえて", "わからない", "分からない", "わかりません", "分かりません", "降参", "こうさん", "ギブアップ"]
            .contains { t.contains(normalize($0)) }
    }

    static func asksForHint(_ text: String) -> Bool {
        let t = normalize(text)
        return ["ヒント", "もうすこし", "もう少し", "もっと"].contains { t.contains(normalize($0)) }
    }

    /// True when the text contains one of the answer keywords (ignoring spaces, "さん", kana type, width).
    public static func matches(_ text: String, keywords: [String]) -> Bool {
        let t = normalize(text)
        return keywords.map(normalize).contains { !$0.isEmpty && t.contains($0) }
    }

    static func normalize(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.applyingTransform(.hiraganaToKatakana, reverse: false) ?? t
        t = t.lowercased()
        for drop in ["サン", "様", "サマ", " ", "　", "、", "。", ",", "?", "？", "!", "！"] {
            t = t.replacingOccurrences(of: drop, with: "")
        }
        return t
    }
}
