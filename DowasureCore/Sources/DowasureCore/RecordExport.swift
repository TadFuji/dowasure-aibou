import Foundation

/// Plain text of all records, for the family to keep a copy (e.g. save to Files or send to themselves).
/// The records stay on the iPhone; this only makes a readable copy when someone asks for it.
public enum RecordExport {
    public static func text(_ records: [DayRecord], exportedOn today: Date = Date(),
                            dayCalendar: DayCalendar = DayCalendar()) -> String {
        let days = records.sorted { $0.date < $1.date }
        var lines = ["ど忘れ相棒の記録（\(longLabel(dayCalendar.key(for: today), dayCalendar))に書き出し、\(days.count)日分）", ""]
        for record in days {
            lines.append("■ \(longLabel(record.date, dayCalendar))")
            let spoken = record.transcript.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if !spoken.isEmpty {
                lines.append("話したこと:")
                lines.append(contentsOf: spoken)
            }
            let summary = record.extraction.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                lines.append("まとめ: \(summary)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// File name such as "ど忘れ相棒の記録_2026-11-07.txt".
    public static func fileName(exportedOn today: Date = Date(), dayCalendar: DayCalendar = DayCalendar()) -> String {
        "ど忘れ相棒の記録_\(dayCalendar.key(for: today)).txt"
    }

    /// "2026年11月7日"
    static func longLabel(_ key: String, _ dayCalendar: DayCalendar) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        return "\(parts[0])年\(parts[1])月\(parts[2])日"
    }
}
