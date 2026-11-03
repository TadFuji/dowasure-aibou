import Foundation

/// System prompts and JSON schemas. Kept fixed so prompt caching can reuse them.
public enum Prompts {
    public static let extractionSystem = """
    あなたは、高齢の利用者がその日の出来事を話した記録を整理する係です。
    入力は、利用者がその日に「覚えておきたい」と話したこと（行頭の [時:分] は話した時刻）、または会話の全文です（「聞き手:」は質問、「本人:」が利用者の言葉）。本人の言葉だけを根拠にしてください。「今日の4時」「来週」などの言い方は、話した日を基準にそのまま残してください。次の決まりを守って、決められた形で返してください。

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

    public static let interviewSystem = """
    あなたは、高齢の利用者の一日の出来事を、夜にやさしく聞き取る聞き手です。利用者は声で答え、あなたの言葉は読み上げられます。
    次の決まりを守って、次に話す言葉を決められた形で返してください。

    - say: 次に話す言葉。敬語で、短く（1〜2文）。一度に聞くことは1つだけ。done が false の時は、必ず質問で終える。
    - done: 聞き取りを終える時だけ true。その時の say は、短いねぎらいと「今日はここまでにしますね」という締めの言葉にする。
    - 聞く内容の目安は、会った人・話した人、決めたことや約束、出かけた場所、明日以降に覚えておきたいこと。朝・昼・夕方の順に聞くとよい。
    - 答えに名前・日付・場所が出てきたら、自然に1回だけ確かめる（例「山田さん、とおっしゃいましたか？」）。確かめる回は、それだけを聞く（次の話題はその次の回にする）。同じことを何度も聞かない。
    - 思い出せないと言われたら責めずに次へ進む。「特にない」「疲れた」などの時や、聞くことがなくなった時は、すぐに終える。
    - 医療や健康についての助言・判断はしない。体調の話が出ても、聞き流して次へ進む。
    - 記録のための聞き取りなので、意見や説教はしない。相づちは短く、相手の気持ち（楽しかった等）を決めつけない。
    """

    public static let interviewSchema: JSONValue = Schema.object([
        "say": Schema.string,
        "done": ["type": "boolean"],
    ])

    public static let answerSystem = """
    あなたは、高齢の利用者の「ど忘れ」を手伝う係です。利用者の質問と、利用者自身が残した記録（日付つき）が渡されます。
    いきなり答えを言うのではなく、まずヒントで本人に思い出してもらうのが目的です。次の決まりを守って、決められた形で返してください。

    - 渡された記録に書かれていることだけを根拠にする。記録に無いことを推測で作らない。
    - 答えが記録にある時: found を true にする。
      - answer: 短い答えを1〜2文で（日付は書かなくてよい）。
      - hints: 本人が自分で思い出せるようなヒントを、弱いものから順に2つ。答えそのもの（名前・数字・場所の名前など）は絶対に書かない。1つ目は状況（いつ・どこで・何をしていた時か）、2つ目はもう少し近づくもの（例「お名前は『も』で始まります」「丸い眼鏡をかけた方です」）。それぞれ1文。
      - answer_keywords: 本人が思い出して口にした時に「正解」とみなせる言葉。名前なら漢字と読み（ひらがな）の両方（例「森田」「もりた」）。数字なら数字の書き方の違いも（例「8500」「8,500」「八千五百」）。
      - evidence_dates: 根拠にした記録の日付（記録に書かれた yyyy-MM-dd の形）をすべて。
    - 答えが記録に無い時: found を false、answer・hints・answer_keywords・evidence_dates を空にする。followup_question に、思い出す手がかりになるやさしい質問を1つ書く（例「その方とは、どこで会いましたか？」）。
    - confidence: 記録にはっきり書いてあれば high、手がかりから推し量った場合は medium、候補が複数あるなど迷う場合は low。
    - 候補が複数ある時は、answer でそう伝え、followup_question で絞り込む質問をしてよい。不要なら空にする。
    - 敬語で、やさしく、短く。医療的な判断や助言はしない。
    """

    public static let answerSchema: JSONValue = Schema.object([
        "found": ["type": "boolean"],
        "answer": Schema.string,
        "hints": Schema.array(Schema.string),
        "answer_keywords": Schema.array(Schema.string),
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
            // Things the user asked to remember are short lines ("[16:05] にんじんを買う");
            // include them as spoken, so nothing depends on the summary alone.
            let memos = record.transcript.split(separator: "\n").filter { $0.hasPrefix("[") }
            if !memos.isEmpty {
                lines.append("話したこと: " + memos.joined(separator: "／"))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "・")
    }
}
