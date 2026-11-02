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
}
