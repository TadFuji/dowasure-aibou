import Foundation
import DowasureCore

// Evaluation harness for the "ask" feature.
// Offline (default): retrieval recall only, no network.
// --live: also runs Answerer against the Claude API and scores the answers.

struct EvalQuestion: Codable {
    var id: String
    var question: String
    var today: String
    var expectedFound: Bool
    var expectedDates: [String]
    var expectedKeywords: [String]
    var category: String

    enum CodingKeys: String, CodingKey {
        case id, question, today, category
        case expectedFound = "expected_found"
        case expectedDates = "expected_dates"
        case expectedKeywords = "expected_keywords"
    }
}

struct QuestionResult: Codable {
    var id: String
    var category: String
    var expectedFound: Bool
    var candidateDates: [String]
    var retrievalHit: Bool?      // answerable questions only
    var retrievalRank: Int?      // 1-based rank of the first expected date among candidates
    var live: Bool
    var gotFound: Bool?
    var answer: String?
    var evidenceDates: [String]?
    var correct: Bool?
    var error: String?
}

struct Summary: Codable {
    var mode: String
    var generatedAt: String
    var questionCount: Int
    var answerableCount: Int
    var unanswerableCount: Int
    var retrievalRecall: Double
    var retrievalRecallAt1: Double
    var answerAccuracy: Double?
    var noInventionRate: Double?
    var errorCount: Int?
}

struct Output: Codable {
    var summary: Summary
    var results: [QuestionResult]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func pct(_ n: Int, _ d: Int) -> Double { d == 0 ? 0 : Double(n) / Double(d) }
func fmt(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

// Package directory: Sources/DowasureEval/main.swift -> ../../
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let live = CommandLine.arguments.contains("--live")

func load<T: Decodable>(_ type: T.Type, _ name: String) -> T {
    let url = packageDir.appendingPathComponent("Fixtures/\(name)")
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
    catch { fail("Cannot load \(url.path): \(error)") }
}

let records = load([DayRecord].self, "eval_records.json")
let questions = load([EvalQuestion].self, "eval_questions.json")

let tokyo = DayCalendar(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
let retriever = Retriever(dayCalendar: tokyo)

/// The moment a question is asked: noon on `today`. Records after that day do not exist yet.
func asked(_ key: String) -> Date {
    guard let d = tokyo.date(from: key) else { fail("Bad date: \(key)") }
    return d.addingTimeInterval(12 * 3600)
}

func readAPIKey() -> String {
    if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
    let url = packageDir.appendingPathComponent("../secrets/anthropic_api_key").standardizedFileURL
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        fail("No API key: set ANTHROPIC_API_KEY or put it in ../secrets/anthropic_api_key")
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { fail("API key file is empty") }
    return key
}

var answerer: Answerer?
if live { answerer = Answerer(client: ClaudeClient(apiKey: readAPIKey()), retriever: retriever) }

var results: [QuestionResult] = []
for q in questions {
    let visible = records.filter { $0.date <= q.today }
    let now = asked(q.today)
    let candidates = retriever.candidates(for: q.question, in: visible, today: now).map(\.date)

    var r = QuestionResult(id: q.id, category: q.category, expectedFound: q.expectedFound,
                           candidateDates: candidates, live: live)
    if q.expectedFound {
        let rank = candidates.firstIndex(where: q.expectedDates.contains).map { $0 + 1 }
        r.retrievalRank = rank
        r.retrievalHit = rank != nil
    }
    if let answerer {
        do {
            let a = try await answerer.answer(q.question, records: visible, today: now)
            r.answer = a.answer
            switch a.kind {
            case .found(let dates):
                r.gotFound = true
                r.evidenceDates = dates
            case .notFound:
                r.gotFound = false
                r.evidenceDates = []
            }
            if q.expectedFound {
                let datesOK = !Set(r.evidenceDates ?? []).isDisjoint(with: q.expectedDates)
                let keywordOK = q.expectedKeywords.contains { a.answer.contains($0) }
                r.correct = r.gotFound == true && datesOK && keywordOK
            } else {
                r.correct = r.gotFound == false
            }
        } catch {
            r.error = error.localizedDescription
            r.correct = false
        }
    }
    results.append(r)
}

// Summary
let answerable = results.filter(\.expectedFound)
let unanswerable = results.filter { !$0.expectedFound }
let recallHits = answerable.filter { $0.retrievalHit == true }.count
let top1Hits = answerable.filter { $0.retrievalRank == 1 }.count

var summary = Summary(
    mode: live ? "live" : "offline",
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    questionCount: results.count,
    answerableCount: answerable.count,
    unanswerableCount: unanswerable.count,
    retrievalRecall: pct(recallHits, answerable.count),
    retrievalRecallAt1: pct(top1Hits, answerable.count))
if live {
    summary.answerAccuracy = pct(answerable.filter { $0.correct == true }.count, answerable.count)
    summary.noInventionRate = pct(unanswerable.filter { $0.gotFound == false }.count, unanswerable.count)
    summary.errorCount = results.filter { $0.error != nil }.count
}

// Table
print("id   category                  exp   cand#  rank  " + (live ? "got   ok   " : "") + "question")
for (q, r) in zip(questions, results) {
    let rank = r.retrievalRank.map(String.init) ?? (r.expectedFound ? "-" : "n/a")
    var line = q.id.padding(toLength: 4, withPad: " ", startingAt: 0) + " "
        + r.category.padding(toLength: 25, withPad: " ", startingAt: 0) + " "
        + (r.expectedFound ? "yes" : "no ").padding(toLength: 5, withPad: " ", startingAt: 0)
        + String(r.candidateDates.count).padding(toLength: 6, withPad: " ", startingAt: 0)
        + rank.padding(toLength: 5, withPad: " ", startingAt: 0) + " "
    if live {
        let got = r.error != nil ? "ERR" : (r.gotFound == true ? "yes" : "no")
        line += got.padding(toLength: 5, withPad: " ", startingAt: 0) + " "
            + (r.correct == true ? "OK" : "NG").padding(toLength: 4, withPad: " ", startingAt: 0) + " "
    }
    print(line + q.question)
    if let e = r.error { print("       error: \(e)") }
}

print("")
print("mode: \(summary.mode)")
print("questions: \(summary.questionCount) (answerable \(summary.answerableCount), unanswerable \(summary.unanswerableCount))")
print("retrieval recall (correct day among candidates): \(recallHits)/\(answerable.count) = \(fmt(summary.retrievalRecall))")
print("retrieval recall@1: \(top1Hits)/\(answerable.count) = \(fmt(summary.retrievalRecallAt1))")
if live {
    print("answer accuracy: \(answerable.filter { $0.correct == true }.count)/\(answerable.count) = \(fmt(summary.answerAccuracy ?? 0))")
    print("no-invention rate: \(unanswerable.filter { $0.gotFound == false }.count)/\(unanswerable.count) = \(fmt(summary.noInventionRate ?? 0))")
    print("errors: \(summary.errorCount ?? 0)")
}

// Write results
let outDir = packageDir.appendingPathComponent("eval-results")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try enc.encode(Output(summary: summary, results: results)).write(to: outDir.appendingPathComponent("latest.json"))
    print("wrote eval-results/latest.json")
} catch {
    fail("Cannot write results: \(error)")
}
