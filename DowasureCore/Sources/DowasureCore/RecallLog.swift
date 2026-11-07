import Foundation

/// The times the user recalled something by themselves from the hints, before asking for the answer.
/// Kept only on the device. Used to encourage ("この1週間で、ご自分で3回思い出せました"),
/// never to score or judge: the times they could not recall are not counted or shown.
public struct RecallLog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var date: Date
        /// How many hints had been given when they named it (1 = the first hint was enough).
        public var hintsUsed: Int
    }

    /// Enough for about two years of daily use, so the stored data stays small.
    public static let maxEntries = 1000

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public mutating func add(at date: Date, hintsUsed: Int) {
        entries.append(Entry(date: date, hintsUsed: max(1, hintsUsed)))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Times recalled in the last 7 days, counting today.
    public func countInLastWeek(now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return 0 }
        return entries.filter { $0.date >= start && $0.date <= now }.count
    }

    /// Words for the home screen, or nil when there is nothing to praise yet (no "0回").
    public static func homeMessage(weekCount: Int) -> String? {
        guard weekCount > 0 else { return nil }
        return "この1週間で、ご自分で\(weekCount)回思い出せました。"
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decoded(from data: Data?) -> RecallLog {
        guard let data, let log = try? JSONDecoder().decode(RecallLog.self, from: data) else { return RecallLog() }
        return log
    }
}
