import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Without an API key, asking a question shows a clear message instead of crashing.
    func testAskWithoutKeyShowsGuidance() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-no-voice", "-uitest-load-samples"]
        app.launch()

        app.buttons["askButton"].tap()
        let input = app.textFields["askInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        XCTAssertTrue(app.staticTexts["APIキーが設定されていません。設定画面で入力してください。"].waitForExistence(timeout: 10))
    }

    /// Turning on the evening reminder asks for permission and confirms the time.
    func testEnablingReminderSchedulesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-no-voice"]
        app.launch()
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["reminderToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) == "1" { toggle.switches.firstMatch.tap() }
        toggle.switches.firstMatch.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["許可"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let message = app.staticTexts["reminderMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // On the iOS 26.5 simulator, usernotificationsd refuses authorization ("requestAuthorization
        // not allowed"), so the app must at least explain it. On a real iPhone it schedules.
        XCTAssertTrue(message.label.contains("にお知らせします") || message.label.contains("通知が許可されていません"), message.label)
    }

    /// An item is saved even without an API key, read back, and can be taken back.
    func testRememberAndUndoWithoutKey() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-no-voice"]
        app.launch()
        app.buttons["talkButton"].tap()
        let input = app.textFields["answerInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("にんじんを買う")
        app.buttons["sendAnswer"].tap()
        XCTAssertTrue(app.staticTexts["「にんじんを買う」ですね。覚えました。"].waitForExistence(timeout: 5))
        // The saved line is read to VoiceOver as "16時05分、にんじんを買う".
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "分、にんじんを買う")).firstMatch.exists)
        app.buttons["undoButton"].tap()
        XCTAssertTrue(app.staticTexts["取り消しました。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "分、にんじんを買う")).firstMatch.exists)
    }

    /// Saving the key shows a confirmation right under the button.
    func testSavingKeyShowsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.buttons["settingsButton"].tap()
        let field = app.secureTextFields.firstMatch
        scrollTo(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("dummy-key-for-ui-test")
        let save = app.buttons["APIキーを保存する"]
        scrollTo(save, in: app)
        save.tap()
        let saved = app.staticTexts["保存しました。"]
        scrollTo(saved, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
    }

    /// Evening conversation with the real API (typed answers), then asking about it.
    func testTalkThenAskWithKey() throws {
        let key = try liveKey()
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-records", "-uitest-no-voice"]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        app.launch()

        // Say something to remember; it is repeated back and listed at once.
        app.buttons["talkButton"].tap()
        XCTAssertTrue(app.staticTexts["覚えておきたいことを、話してください。"].waitForExistence(timeout: 5))
        let input = app.textFields["answerInput"]
        input.tap()
        input.typeText("4時に図書館で、司書の青山さんに本を返す")
        app.buttons["sendAnswer"].tap()
        let confirmation = app.staticTexts["aiQuestion"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.label.contains("覚えました"), confirmation.label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "青山さんに本を返す")).firstMatch.exists)

        // Ask about it: a hint comes first (without the name), the answer when asked for.
        app.buttons["homeButton"].tap()
        app.buttons["askButton"].tap()
        let ask = app.textFields["askInput"]
        ask.tap()
        ask.typeText("今日、本を返す相手の名前")
        app.buttons["askSubmit"].tap()
        let reply = app.staticTexts["answerText"]
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
        XCTAssertTrue(reply.label.hasPrefix("ヒントです"), reply.label)
        XCTAssertFalse(reply.label.contains("青山"), reply.label)
        app.buttons["revealButton"].tap()
        XCTAssertTrue(reply.label.contains("の記録より："), reply.label)
        XCTAssertTrue(reply.label.contains("青山"), reply.label)
    }


    /// Scrolls the current screen until the element exists (Form rows load lazily).
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }

    private func localSecret(_ name: String) -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("secrets/\(name)")
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        app.launchArguments = ["-uitest-reset-records", "-uitest-no-voice", "-uitest-load-samples"]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        // The cloud voice key is not passed: Gemini TTS allows only 100 requests per day per model
        // on Tier 1, and that quota is needed for the maker's real use.
        app.launch()

        app.buttons["askButton"].tap()
        let input = app.textFields["askInput"]
        input.tap()
        input.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        let answer = app.staticTexts["answerText"]
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        XCTAssertTrue(answer.label.hasPrefix("ヒントです"), answer.label)
        XCTAssertFalse(answer.label.contains("森田"), answer.label)
        // Naming the person (in kana) counts as remembering.
        let guess = app.textFields["guessInput"]
        guess.tap()
        guess.typeText("もりたさん")
        app.buttons["sendGuess"].tap()
        XCTAssertTrue(answer.label.hasPrefix("そうです！"), answer.label)
        XCTAssertTrue(answer.label.contains("の記録より："), answer.label)
    }
}
