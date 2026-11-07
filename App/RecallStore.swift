import Foundation
import DowasureCore

/// Keeps the "recalled by themselves" log on this iPhone only (it is small: about 50 bytes a time).
@MainActor
enum RecallStore {
    static let key = "recallLog"

    static func load() -> RecallLog {
        RecallLog.decoded(from: UserDefaults.standard.data(forKey: key))
    }

    static func add(hintsUsed: Int, at date: Date = Date()) {
        var log = load()
        log.add(at: date, hintsUsed: hintsUsed)
        UserDefaults.standard.set(log.encoded(), forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Words for the home screen, or nil before the first time.
    static func homeMessage(now: Date = Date()) -> String? {
        RecallLog.homeMessage(weekCount: load().countInLastWeek(now: now, calendar: DayCalendar().calendar))
    }
}
