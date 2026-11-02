import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Without an API key, asking a question shows a clear message instead of crashing.
    func testAskWithoutKeyShowsGuidance() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-no-voice"]
        app.launch()

        app.buttons["settingsButton"].tap()
        app.buttons["loadSamples"].tap()
        XCTAssertTrue(app.staticTexts["架空の記録を入れました。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["askButton"].tap()
        let input = app.textFields["askInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        XCTAssertTrue(app.staticTexts["APIキーが設定されていません。設定画面で入力してください。"].waitForExistence(timeout: 10))
    }

    /// Saving the key shows a confirmation right under the button.
    func testSavingKeyShowsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.buttons["settingsButton"].tap()
        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("dummy-key-for-ui-test")
        app.buttons["saveKeyButton"].tap()
        XCTAssertTrue(app.staticTexts["保存しました。"].waitForExistence(timeout: 5))
    }

    /// Evening conversation with the real API (typed answers), then asking about it.
    func testTalkThenAskWithKey() throws {
        let key = try liveKey()
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-records", "-uitest-no-voice"]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        app.launch()

        app.buttons["talkButton"].tap()
        XCTAssertTrue(app.staticTexts["今日は、どなたかと会ったり、話したりしましたか？"].waitForExistence(timeout: 5))
        let input = app.textFields["answerInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("午後に図書館へ行って、司書の青山さんと話しました")
        app.buttons["sendAnswer"].tap()

        // The AI asks a follow-up question; the first question is replaced.
        let firstGone = NSPredicate(format: "label != %@", "今日は、どなたかと会ったり、話したりしましたか？")
        let changed = XCTNSPredicateExpectation(predicate: firstGone, object: app.staticTexts["aiQuestion"])
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 60), .completed)

        app.buttons["endButton"].tap()
        XCTAssertTrue(app.otherElements["savedSummary"].firstMatch.waitForExistence(timeout: 60)
                      || app.staticTexts["記録しました"].waitForExistence(timeout: 1))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["askButton"].tap()
        let ask = app.textFields["askInput"]
        ask.tap()
        ask.typeText("今日図書館で話した人の名前")
        app.buttons["askSubmit"].tap()
        let answer = app.staticTexts["answerText"]
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        XCTAssertTrue(answer.label.contains("の記録より："), answer.label)
        XCTAssertTrue(answer.label.contains("青山"), answer.label)
    }

    private func liveKey() throws -> String {
        let keyFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("secrets/anthropic_api_key")
        let key = (try? String(contentsOf: keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(key.isEmpty, "no local API key; live test skipped")
        return key
    }

    /// Full flow against the real API. Runs only when the local secrets file exists
    /// (secrets/ is git-ignored; the simulator can read the Mac's file system).
    func testAskWithKeyAnswersWithDate() throws {
        let keyFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("secrets/anthropic_api_key")
        let key = (try? String(contentsOf: keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(key.isEmpty, "no local API key; live test skipped")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-records"]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        app.launch()

        app.buttons["settingsButton"].tap()
        app.buttons["loadSamples"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["askButton"].tap()
        let input = app.textFields["askInput"]
        input.tap()
        input.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        let answer = app.staticTexts["answerText"]
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        XCTAssertTrue(answer.label.contains("の記録より："), answer.label)
        XCTAssertTrue(answer.label.contains("森田"), answer.label)
    }
}
