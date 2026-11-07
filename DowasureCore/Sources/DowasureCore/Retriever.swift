import Foundation

/// Converts between `Date` and the "yyyy-MM-dd" day key, in the user's calendar.
public struct DayCalendar: Sendable {
    public var calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "ja_JP")
        cal.firstWeekday = 2 // Monday
        self.calendar = cal
    }

    public func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "10月8日" style label used when reading evidence dates aloud.
    public func spokenLabel(for key: String) -> String {
        guard let d = date(from: key) else { return key }
        let c = calendar.dateComponents([.month, .day], from: d)
        return "\(c.month!)月\(c.day!)日"
    }

    func addDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: calendar.startOfDay(for: date))!
    }
}

/// Picks the few records worth sending to the model for a question.
/// Deterministic and on-device: date words narrow the range, then word overlap ranks the days.
public struct Retriever: Sendable {
    public var dayCalendar: DayCalendar
    public var maxRecords: Int

    public init(dayCalendar: DayCalendar = DayCalendar(), maxRecords: Int = 7) {
        self.dayCalendar = dayCalendar
        self.maxRecords = maxRecords
    }

    /// Inclusive range of day keys implied by time words in the question, or nil if none.
    public func dateRange(in question: String, today: Date) -> ClosedRange<String>? {
        // "昨日会った人の名前（先週）": the reply in brackets corrects the time, so it is read first.
        if question.hasSuffix("）"), let open = question.lastIndex(of: "（") {
            let reply = String(question[question.index(after: open)..<question.index(before: question.endIndex)])
            let base = String(question[..<open])
            return dateRange(in: reply, today: today) ?? dateRange(in: base, today: today)
        }
        let cal = dayCalendar.calendar
        let todayStart = cal.startOfDay(for: today)
        func range(_ from: Date, _ to: Date) -> ClosedRange<String> {
            dayCalendar.key(for: from)...dayCalendar.key(for: to)
        }
        func day(_ offset: Int) -> Date { dayCalendar.addDays(offset, to: todayStart) }

        // Explicit date: "10月8日"
        if let m = question.firstMatch(of: /(\d{1,2})月(\d{1,2})日/),
           let month = Int(m.1), let dayOfMonth = Int(m.2) {
            var year = cal.component(.year, from: today)
            if let d = cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth)), d > todayStart {
                year -= 1
            }
            if let d = cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) {
                return range(d, d)
            }
        }
        // "3日前"
        if let m = question.firstMatch(of: /(\d+)日前/), let n = Int(m.1) {
            return range(day(-n - 1), day(-n + 1))
        }
        if question.contains("おととい") || question.contains("一昨日") { return range(day(-2), day(-2)) }
        if question.contains("昨日") || question.contains("きのう") { return range(day(-1), day(-1)) }
        if question.contains("今日") || question.contains("きょう") { return range(todayStart, todayStart) }

        let weekStart = cal.dateInterval(of: .weekOfYear, for: todayStart)!.start
        if question.contains("先週") { return range(dayCalendar.addDays(-7, to: weekStart), dayCalendar.addDays(-1, to: weekStart)) }
        if question.contains("今週") { return range(weekStart, todayStart) }

        let monthStart = cal.dateInterval(of: .month, for: todayStart)!.start
        if question.contains("先月") {
            let prevStart = cal.date(byAdding: .month, value: -1, to: monthStart)!
            return range(prevStart, dayCalendar.addDays(-1, to: monthStart))
        }
        if question.contains("今月") { return range(monthStart, todayStart) }

        if ["最近", "この前", "このあいだ", "この間", "こないだ"].contains(where: question.contains) {
            return range(day(-14), todayStart)
        }
        return nil
    }

    /// Returns candidate records, best first, newest first on ties.
    public func candidates(for question: String, in records: [DayRecord], today: Date) -> [DayRecord] {
        var pool = records
        if let range = dateRange(in: question, today: today) {
            pool = records.filter { range.contains($0.date) }
        }
        let qGrams = Self.bigrams(Self.normalize(question))
        let scored = pool.map { record -> (DayRecord, Int) in
            (record, score(record, question: question, questionGrams: qGrams))
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .prefix(maxRecords)
            .map(\.0)
    }

    func score(_ record: DayRecord, question: String, questionGrams: Set<String>) -> Int {
        let e = record.extraction
        var s = 0
        // Strong signal: a stored name appears in the question.
        let names = e.people.map(\.name) + e.places.map(\.name)
        for name in names {
            let core = name.replacingOccurrences(of: "さん", with: "")
            if core.count >= 2 && question.contains(core) { s += 10 }
        }
        // Weak signal: shared character pairs with the record's text.
        let text = Self.normalize(Prompts.renderRecords([record]))
        s += questionGrams.intersection(Self.bigrams(text)).count
        // Single kanji nouns (e.g. "柿") are missed by pairs, so shared kanji count too.
        s += 2 * Self.kanji(Self.normalize(question)).intersection(Self.kanji(text)).count
        return s
    }

    static let ignoredGrams: Set<String> = ["何だ", "だっ", "っけ", "あれ", "って", "した", "です", "ます", "けど", "たっ", "ので", "った", "いた"]

    static let ignoredKanji: Set<Character> = ["何", "先", "今", "月", "日", "週", "年", "前", "後", "時", "個", "人", "行", "会", "言", "思", "出", "入", "見", "来", "最", "近", "間"]

    static func kanji(_ s: String) -> Set<Character> {
        Set(s.filter { ch in
            ch.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } && !ignoredKanji.contains(ch)
        })
    }

    static func normalize(_ s: String) -> String {
        s.applyingTransform(.fullwidthToHalfwidth, reverse: false)?.lowercased() ?? s.lowercased()
    }

    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count >= 2 else { return [] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            let g = String(chars[i...i + 1])
            if !ignoredGrams.contains(g) { out.insert(g) }
        }
        return out
    }
}
