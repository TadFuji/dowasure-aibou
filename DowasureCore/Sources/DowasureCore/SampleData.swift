import Foundation

/// Fictional records for trying the app without real personal data.
/// All names, places and numbers are made up.
public enum SampleData {
    /// Days are placed relative to `today` so that "昨日" or "先週" questions work.
    public static func records(today: Date, dayCalendar: DayCalendar = DayCalendar()) -> [DayRecord] {
        func key(_ daysAgo: Int) -> String {
            dayCalendar.key(for: dayCalendar.addDays(-daysAgo, to: today))
        }
        return [
            DayRecord(date: key(1), transcript: "", extraction: Extraction(
                summary: "午前中に公民館の書道教室へ行った。先生の小川さんに、来月の作品展に出すよう勧められた。帰りにパン屋でクリームパンを買った。",
                people: [.init(name: "小川さん", relation: "書道教室の先生", note: "作品展への出品を勧めてくれた")],
                promises: [.init(what: "作品展に出す作品を仕上げる", with: "小川さん", due: "来月")],
                places: [.init(name: "公民館"), .init(name: "パン屋", note: "クリームパンがおいしい")],
                events: ["書道教室に参加した"])),
            DayRecord(date: key(3), transcript: "", extraction: Extraction(
                summary: "駅前の喫茶店で、元同僚の森田さんと久しぶりに会った。森田さんは丸い眼鏡をかけていた。お互いの孫の話をした。",
                people: [.init(name: "森田さん", relation: "元同僚", note: "丸い眼鏡。孫が二人いる")],
                places: [.init(name: "駅前の喫茶店")],
                events: ["孫の話をした"])),
            DayRecord(date: key(5), transcript: "", extraction: Extraction(
                summary: "歯医者に行った。次の予約を取った。午後は庭の手入れをした。",
                promises: [.init(what: "歯医者の予約", with: "", due: "再来週の水曜 午前10時半")],
                places: [.init(name: "さくら歯科")],
                numbers: [.init(label: "歯医者の予約時刻", value: "10時半")],
                events: ["庭の手入れをした"])),
            DayRecord(date: key(9), transcript: "", extraction: Extraction(
                summary: "娘の由美が孫の翔太を連れて遊びに来た。翔太の誕生日が来月12日だと聞いた。",
                people: [.init(name: "由美", relation: "娘"), .init(name: "翔太", relation: "孫", note: "誕生日は来月12日")],
                numbers: [.init(label: "翔太の誕生日", value: "来月12日")],
                events: ["娘と孫が遊びに来た"])),
            DayRecord(date: key(12), transcript: "", extraction: Extraction(
                summary: "町内会の集まりに出た。会長の石井さんから、清掃活動の日にちを聞いた。",
                people: [.init(name: "石井さん", relation: "町内会長")],
                promises: [.init(what: "清掃活動に参加する", with: "町内会", due: "今月の最終日曜 朝8時")],
                places: [.init(name: "町内会館")],
                events: ["町内会の集まりに出た"])),
        ]
    }
}
