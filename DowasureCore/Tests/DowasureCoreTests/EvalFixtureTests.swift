import Foundation
import Testing
@testable import DowasureCore

@Suite struct EvalFixtureTests {
    struct Question: Decodable {
        var id: String
        var question: String
        var today: String
        var expected_found: Bool
        var expected_dates: [String]
        var expected_keywords: [String]
        var category: String
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent(name)))
    }

    @Test func fixturesDecodeAndAreConsistent() throws {
        let records = try load([DayRecord].self, "eval_records.json")
        let questions = try load([Question].self, "eval_questions.json")
        #expect(records.count == 25)
        #expect(questions.count == 30)

        let dates = Set(records.map(\.date))
        #expect(dates.count == records.count)
        for r in records { #expect(tokyo.date(from: r.date) != nil, "bad record date \(r.date)") }

        #expect(Set(questions.map(\.id)).count == questions.count)
        for q in questions {
            #expect(tokyo.date(from: q.today) != nil, "bad today in \(q.id)")
            for d in q.expected_dates { #expect(dates.contains(d), "\(q.id): \(d) not in records") }
            if q.expected_found {
                #expect(!q.expected_dates.isEmpty && !q.expected_keywords.isEmpty, "\(q.id) lacks expectations")
            } else {
                #expect(q.expected_dates.isEmpty, "\(q.id) is unanswerable but lists dates")
            }
        }
        #expect(questions.filter { !$0.expected_found }.count >= 8)
    }
}
