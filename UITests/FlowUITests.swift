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
        XCTAssertTrue(app.staticTexts["まだ使う準備ができていません。ご家族か、設定をした方に「はじめの準備」をお願いしてください。"].waitForExistence(timeout: 10))
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
        // The undo can itself be taken back (final review, 2026-11-08).
        app.buttons["redoButton"].tap()
        XCTAssertTrue(app.staticTexts["元に戻しました。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "分、にんじんを買う")).firstMatch.exists)
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
        // On this screen size the hint buttons can sit under the floating "ホームにもどる" bar.
        // XCTest then tapped without scrolling and the tap missed (two of five runs on 11/07).
        // Scroll to the end first, so the button is fully above the bar.
        let revealButton = app.buttons["revealButton"]
        XCTAssertTrue(revealButton.waitForExistence(timeout: 5))
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        app.scrollViews.firstMatch.swipeUp()
        revealButton.tap()
        // The text changes a moment after the tap; wait for it instead of reading the old hint.
        let revealed = expectation(for: NSPredicate(format: "label CONTAINS %@", "の記録より："), evaluatedWith: reply)
        wait(for: [revealed], timeout: 5)
        XCTAssertTrue(reply.label.contains("青山"), reply.label)
    }


    /// Scrolls the current screen until the element exists (Form rows load lazily).
    /// Swipes the list itself: the middle of the whole app can be the bottom button area (2026-11-07).
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 8 {
            if list.exists { list.swipeUp() } else { app.swipeUp() }
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
        // Back home, the time they recalled it themselves is shown as encouragement.
        app.buttons["homeButton"].tap()
        let recall = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ご自分で1回思い出せました")).firstMatch
        XCTAssertTrue(recall.waitForExistence(timeout: 5))
    }

    /// The "どうぞ、お話しください" sign stays above the bottom buttons however long the hint is,
    /// even with the largest text size (it went under them on 藤川さん's iPhone, 2026-11-08).
    /// Uses the real API for a hint; the microphone is replaced by "-uitest-fake-listening".
    func testListeningSignVisibleOnHintScreen() throws {
        let keyFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("secrets/anthropic_api_key")
        let key = (try? String(contentsOf: keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(key.isEmpty, "no local API key; live test skipped")
        // The usual text size, and a large accessibility size.
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityL"] {
            try checkListeningSign(key: key, textSize: size)
        }
    }

    private func checkListeningSign(key: String, textSize: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-records", "-uitest-no-voice", "-uitest-load-samples",
                               "-uitest-fake-listening",
                               "-UIPreferredContentSizeCategoryName", textSize]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        app.launch()

        app.buttons["askButton"].tap()
        let input = app.textFields["askInput"]
        input.tap()
        input.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        XCTAssertTrue(app.staticTexts["answerText"].waitForExistence(timeout: 60))
        // Close the keyboard if it is still up, then start "listening".
        if app.keyboards.count > 0 { app.swipeDown() }
        let mic = app.buttons["micButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        let sign = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "どうぞ、お話しください")).firstMatch
        let signShown = sign.waitForExistence(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "listening-sign-on-hint-screen-\(textSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(signShown, textSize)
        // Wholly above the bottom area (whose top is the microphone button).
        XCTAssertTrue(sign.isHittable)
        XCTAssertLessThan(sign.frame.maxY, mic.frame.minY, "sign \(sign.frame) vs mic \(mic.frame)")
    }
}
