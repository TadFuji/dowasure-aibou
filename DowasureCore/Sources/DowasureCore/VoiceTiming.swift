import Foundation

/// How long the microphone keeps listening while nothing new is heard.
/// Older users often think before speaking, so the wait before the first words is long,
/// and the pause that ends an answer is a little longer than usual.
public enum VoiceTiming {
    public static let waitForFirstWords: TimeInterval = 20
    public static let pauseAfterSpeech: TimeInterval = 4

    public static func silenceTimeout(heardSomething: Bool) -> TimeInterval {
        heardSomething ? pauseAfterSpeech : waitForFirstWords
    }

    /// Shown when nothing was heard. It names the microphone button as it reads on that screen
    /// (2026-11-08, 藤川さん: the hint screen said 「声で話す」 though its button is 「思い出したことを言う」).
    public static func silenceMessage(buttonTitle: String) -> String {
        "お話が聞こえなかったので、いったん止めました。「\(buttonTitle)」を押してお話しください。"
    }
}
