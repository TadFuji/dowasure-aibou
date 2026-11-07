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
        // Spoken numbers may come as kanji ("三か月前", "五月").
        let q = Self.arabicNumerals(question)
        let cal = dayCalendar.calendar
        let todayStart = cal.startOfDay(for: today)
        func range(_ from: Date, _ to: Date) -> ClosedRange<String> {
            dayCalendar.key(for: from)...dayCalendar.key(for: to)
        }
        func day(_ offset: Int) -> Date { dayCalendar.addDays(offset, to: todayStart) }

        // Explicit date: "10月8日"
        if let m = q.firstMatch(of: /(\d{1,2})月(\d{1,2})日/),
           let month = Int(m.1), let dayOfMonth = Int(m.2) {
            var year = cal.component(.year, from: today)
            if let d = cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth)), d > todayStart {
                year -= 1
            }
            if let d = cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) {
                return range(d, d)
            }
        }
        let year = cal.component(.year, from: todayStart)
        let lastYear = q.contains("去年") || q.contains("昨年")
        func ymd(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        func months(_ y: Int, _ m: Int, count: Int) -> ClosedRange<String> {
            let start = ymd(y, m, 1)
            return range(start, dayCalendar.addDays(-1, to: cal.date(byAdding: .month, value: count, to: start)!))
        }

        // A month alone: "5月に", "去年の5月" (the most recent May, or last year's)
        if let m = q.firstMatch(of: /(\d{1,2})月/), let month = Int(m.1), (1...12).contains(month) {
            var y = lastYear ? year - 1 : year
            if !lastYear && ymd(y, month, 1) > todayStart { y -= 1 }
            return months(y, month, count: 1)
        }
        // "3か月前", "半年前": about that time, give or take three weeks
        let monthsAgo = q.firstMatch(of: /(\d+)\s*(?:か|ヶ|カ|ケ|ヵ|箇)月前/).flatMap { Int($0.1) } ?? (q.contains("半年前") ? 6 : nil)
        if let n = monthsAgo {
            let center = cal.date(byAdding: .month, value: -n, to: todayStart)!
            return range(dayCalendar.addDays(-20, to: center), min(dayCalendar.addDays(20, to: center), todayStart))
        }
        // "2週間前": that week, give or take a few days
        if let m = q.firstMatch(of: /(\d+)\s*週間前/), let n = Int(m.1) {
            return range(day(-7 * n - 4), min(day(-7 * n + 4), todayStart))
        }
        // Seasons: "夏ごろ", "去年の冬". Spring Mar–May, summer Jun–Aug, autumn Sep–Nov, winter Dec–Feb.
        if let m = q.firstMatch(of: /(春|夏|秋|冬)(?:に|ごろ|頃|の|先|休み|場)/) {
            let startMonth = ["春": 3, "夏": 6, "秋": 9, "冬": 12][String(m.1)]!
            var y = lastYear ? year - 1 : year
            if !lastYear && ymd(y, startMonth, 1) > todayStart { y -= 1 }
            return months(y, startMonth, count: 3)
        }
        if lastYear { return range(ymd(year - 1, 1, 1), ymd(year - 1, 12, 31)) }
        if q.contains("今年") { return range(ymd(year, 1, 1), todayStart) }

        // "3日前"
        if let m = q.firstMatch(of: /(\d+)日前/), let n = Int(m.1) {
            return range(day(-n - 1), day(-n + 1))
        }
        if q.contains("おととい") || q.contains("一昨日") { return range(day(-2), day(-2)) }
        if q.contains("昨日") || q.contains("きのう") { return range(day(-1), day(-1)) }
        if q.contains("今日") || q.contains("きょう") { return range(todayStart, todayStart) }

        let weekStart = cal.dateInterval(of: .weekOfYear, for: todayStart)!.start
        if q.contains("先週") { return range(dayCalendar.addDays(-7, to: weekStart), dayCalendar.addDays(-1, to: weekStart)) }
        if q.contains("今週") { return range(weekStart, todayStart) }

        let monthStart = cal.dateInterval(of: .month, for: todayStart)!.start
        if q.contains("先月") {
            let prevStart = cal.date(byAdding: .month, value: -1, to: monthStart)!
            return range(prevStart, dayCalendar.addDays(-1, to: monthStart))
        }
        if q.contains("今月") { return range(monthStart, todayStart) }

        if ["最近", "この前", "このあいだ", "この間", "こないだ"].contains(where: q.contains) {
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

    /// "三か月前" → "3か月前", "十二月" → "12月". Only numbers followed by a time unit are changed,
    /// so words such as "一昨日" stay as they are.
    static func arabicNumerals(_ s: String) -> String {
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        func value(_ run: [Character]) -> Int? {
            guard let ten = run.firstIndex(of: "十") else {
                return run.count == 1 ? digits[run[0]] : nil
            }
            let before = run[..<ten], after = run[(ten + 1)...]
            guard before.count <= 1, after.count <= 1 else { return nil }
            let tens = before.first.map { digits[$0] ?? 0 } ?? 1
            let ones = after.first.map { digits[$0] ?? 0 } ?? 0
            return tens * 10 + ones
        }
        var out = ""
        var run: [Character] = []
        func flush(before next: Character?) {
            guard !run.isEmpty else { return }
            if let next, "月かヶカケヵ箇週日".contains(next), let n = value(run) {
                out += String(n)
            } else {
                out += String(run)
            }
            run = []
        }
        for ch in s {
            if digits[ch] != nil || ch == "十" {
                run.append(ch)
            } else {
                flush(before: ch)
                out.append(ch)
            }
        }
        flush(before: nil)
        return out
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
