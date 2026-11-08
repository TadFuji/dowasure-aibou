import Foundation

/// The "recall it yourself" conversation after a question: hints first, the answer only when asked
/// or when the user names it. Runs on the device with no extra AI calls, so replies are instant.
public struct HintSession: Sendable, Equatable {
    public struct Reply: Sendable, Equatable {
        public var text: String
        public var revealed: Bool
        /// True only when the user named the answer from the hints, before asking for it.
        public var recalledByThemselves: Bool = false

        public init(text: String, revealed: Bool, recalledByThemselves: Bool = false) {
            self.text = text
            self.revealed = revealed
            self.recalledByThemselves = recalledByThemselves
        }
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
        if Self.isCorrectGuess(utterance, keywords: answer.answerKeywords) {
            revealed = true
            return Reply(text: "そうです！ご自分で思い出せましたね。\n\(answer.displayText)", revealed: true,
                         recalledByThemselves: true)
        }
        let prefix = Self.asksForHint(utterance) ? "" : Self.notMatchedPrefix(utterance)
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

    /// Says what was heard, so a right name heard in different characters (e.g. 守田 for 森田)
    /// is not simply called wrong, and points to "答えを教えて" for checking.
    static func notMatchedPrefix(_ utterance: String) -> String {
        let heard = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return "うーん、少し違うようです。\n" }
        let shown = heard.count > 30 ? String(heard.prefix(30)) + "…" : heard
        return "「\(shown)」と聞こえました。記録の言葉とは少し違うようです。\n"
    }

    private mutating func nextHintOrOffer() -> String {
        if hintsGiven < answer.hints.count {
            let hint = answer.hints[hintsGiven]
            hintsGiven += 1
            return "もう一つヒントです。\(hint)"
        }
        return "ヒントは以上です。「答えを教えて」と言っていただければ、お伝えします。"
    }

    // MARK: Understanding the user's words (on-device, simple and predictable)

    /// Only a clear request for the answer reveals it: "答え", "降参", "ギブアップ".
    /// "ヒントを教えて" or "答えのヒント" asks for a hint, and "わからない" or "教えて" alone gets the next hint too,
    /// because the app's aim is to help the user recall it themselves (2026-11-08 final review).
    static func asksForAnswer(_ text: String) -> Bool {
        let t = normalize(text)
        if t.contains(normalize("ヒント")) { return false }
        return ["答え", "こたえ", "降参", "こうさん", "ギブアップ"]
            .contains { t.contains(normalize($0)) }
    }

    /// Asking for more help without asking for the answer: no "と聞こえました" before the next hint.
    static func asksForHint(_ text: String) -> Bool {
        let t = normalize(text)
        return ["ヒント", "もうすこし", "もう少し", "もっと", "教えて", "おしえて",
                "わからない", "分からない", "わかりません", "分かりません", "わかんない",
                "思い出せない", "おもいだせない", "思い出せません", "おもいだせません"]
            .contains { t.contains(normalize($0)) }
    }

    /// True when the text contains one of the answer keywords (ignoring spaces, "さん", kana type, width).
    /// Used strictly, to keep hints from giving the answer away.
    public static func matches(_ text: String, keywords: [String]) -> Bool {
        let t = normalize(text)
        return keywords.map(normalize).contains { !$0.isEmpty && t.contains($0) }
    }

    /// True when the user's guess names the answer. A one-character keyword must be said on its own:
    /// otherwise "森" would accept "森本" for "森".
    static func isCorrectGuess(_ text: String, keywords: [String]) -> Bool {
        let t = normalize(text)
        return keywords.map(normalize).contains { k in
            guard !k.isEmpty else { return false }
            return k.count >= 2 ? t.contains(k) : t == k
        }
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
