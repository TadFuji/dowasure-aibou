import Foundation

/// System prompts and JSON schemas. Kept fixed so prompt caching can reuse them.
public enum Prompts {
    public static let extractionSystem = """
    あなたは、高齢の利用者がその日の出来事を話した記録を整理する係です。
    入力は、その日の会話の全文です。次の決まりを守って、決められた形で返してください。

    - summary: その日の出来事を3〜5文で、利用者の立場から短くまとめる。
    - people: 会った人・話した人。name は話に出た呼び方のまま（例「山田さん」）。relation は間柄（分かれば）、note は特徴や話した内容。
    - promises: 約束や決めたこと。what は内容、with は相手、due は日時（話に出た言い方のまま。例「来週の火曜」）。
    - places: 出かけた場所。
    - numbers: 金額・時刻・部屋番号・電話番号の一部など、覚えておくと役立つ数字。
    - events: 上に入らない出来事を短い文で。
    - 利用者が言っていないことを付け足さない。分からない欄は空の文字列か空の配列にする。
    - 名前の聞き取りが不確かそうな時は、note に「聞き取りが不確か」と書く。
    - 医療的な判断や助言は書かない。
    """

    public static let extractionSchema: JSONValue = Schema.object([
        "summary": Schema.string,
        "people": Schema.array(Schema.object([
            "name": Schema.string, "relation": Schema.string, "note": Schema.string,
        ])),
        "promises": Schema.array(Schema.object([
            "what": Schema.string, "with": Schema.string, "due": Schema.string,
        ])),
        "places": Schema.array(Schema.object([
            "name": Schema.string, "note": Schema.string,
        ])),
        "numbers": Schema.array(Schema.object([
            "label": Schema.string, "value": Schema.string,
        ])),
        "events": Schema.array(Schema.string),
    ])

    public static let answerSystem = """
    あなたは、高齢の利用者の「ど忘れ」を手伝う係です。利用者の質問と、利用者自身が残した記録（日付つき）が渡されます。
    次の決まりを守って、決められた形で返してください。

    - 渡された記録に書かれていることだけを根拠に答える。記録に無いことを推測で作らない。
    - 答えが記録にある時: found を true にし、answer に短い答えを1〜2文で書く（日付は answer に書かなくてよい）。evidence_dates に根拠にした記録の日付（記録に書かれた yyyy-MM-dd の形）をすべて入れる。
    - 答えが記録に無い時: found を false、answer を空、evidence_dates を空にする。followup_question に、思い出す手がかりになるやさしい質問を1つ書く（例「その方とは、どこで会いましたか？」）。
    - confidence: 記録にはっきり書いてあれば high、手がかりから推し量った場合は medium、候補が複数あるなど迷う場合は low。
    - found が true の時も、候補が複数あれば answer でそう伝え、followup_question で絞り込む質問をしてよい。不要なら空にする。
    - 敬語で、やさしく、短く。医療的な判断や助言はしない。
    """

    public static let answerSchema: JSONValue = Schema.object([
        "found": ["type": "boolean"],
        "answer": Schema.string,
        "evidence_dates": Schema.array(Schema.string),
        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
        "followup_question": Schema.string,
    ])

    /// Renders candidate records for the answer prompt (summary + extraction, no full transcript).
    public static func renderRecords(_ records: [DayRecord]) -> String {
        records.map { record in
            let e = record.extraction
            var lines = ["【記録 \(record.date)】", "要約: \(e.summary)"]
            if !e.people.isEmpty {
                lines.append("人: " + e.people.map { joined($0.name, $0.relation, $0.note) }.joined(separator: "／"))
            }
            if !e.promises.isEmpty {
                lines.append("約束: " + e.promises.map { joined($0.what, $0.with, $0.due) }.joined(separator: "／"))
            }
            if !e.places.isEmpty {
                lines.append("場所: " + e.places.map { joined($0.name, $0.note) }.joined(separator: "／"))
            }
            if !e.numbers.isEmpty {
                lines.append("数字: " + e.numbers.map { "\($0.label) \($0.value)" }.joined(separator: "／"))
            }
            if !e.events.isEmpty {
                lines.append("出来事: " + e.events.joined(separator: "／"))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "・")
    }
}
