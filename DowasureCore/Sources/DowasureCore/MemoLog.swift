import Foundation

/// Builds a day's transcript from things the user asked to remember, one line each with the time spoken.
public enum MemoLog {
    public static func line(_ text: String, at date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "[%d:%02d] ", c.hour ?? 0, c.minute ?? 0) + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func appending(_ text: String, at date: Date, to transcript: String, calendar: Calendar = .current) -> String {
        let new = line(text, at: date, calendar: calendar)
        return transcript.isEmpty ? new : transcript + "\n" + new
    }

    /// Spoken confirmation that repeats the user's own words, so a mis-heard word can be noticed.
    public static func confirmation(for text: String) -> String {
        "「\(text.trimmingCharacters(in: .whitespacesAndNewlines))」ですね。覚えました。"
    }
}
