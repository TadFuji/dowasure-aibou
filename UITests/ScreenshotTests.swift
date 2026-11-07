import XCTest

/// Takes the README screenshots with the fictional sample records (SampleData.swift) only.
///
/// Skipped in normal test runs. To take them on the Mac (needs secrets/anthropic_api_key):
///
///     TEST_RUNNER_DOWASURE_SCREENSHOTS=1 xcodebuild test -project DowasureAibou.xcodeproj \
///       -scheme DowasureAibou -destination 'platform=iOS Simulator,id=<id>' \
///       -derivedDataPath build/dd -only-testing:DowasureAibouUITests/ScreenshotTests
///
/// The PNG files go to screenshots-out/ in the repository (git-ignored), and are also kept
/// as attachments in the test result. Pick the good ones and copy them to docs/images/.
/// Added 2026-11-07 so that no real record can end up in a README picture.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureReadmeScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOWASURE_SCREENSHOTS"] == "1",
                          "screenshots are taken only when DOWASURE_SCREENSHOTS=1")
        let key = try liveKey()
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-records", "-uitest-no-voice", "-uitest-load-samples"]
        app.launchEnvironment["DOWASURE_UITEST_API_KEY"] = key
        app.launch()

        XCTAssertTrue(app.buttons["askButton"].waitForExistence(timeout: 5))
        shot("01-home", app)

        // Remember something (typed, because the simulator cannot recognise speech).
        app.buttons["talkButton"].tap()
        let input = app.textFields["answerInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("あさって10時に歯医者")
        app.buttons["sendAnswer"].tap()
        let confirmation = app.staticTexts["aiQuestion"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        shot("02-talk-saved", app)

        // Ask: the first hint, without the name.
        app.buttons["homeButton"].tap()
        app.buttons["askButton"].tap()
        let ask = app.textFields["askInput"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        ask.typeText("駅前で会った眼鏡の人の名前")
        app.buttons["askSubmit"].tap()
        let answer = app.staticTexts["answerText"]
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        XCTAssertTrue(answer.label.hasPrefix("ヒントです"), answer.label)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        shot("03-ask-hint", app)

        // Naming the person counts as remembering.
        let guess = app.textFields["guessInput"]
        XCTAssertTrue(guess.waitForExistence(timeout: 5))
        guess.tap()
        guess.typeText("もりたさん")
        app.buttons["sendGuess"].tap()
        let correct = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "そうです！"), evaluatedWith: answer)
        wait(for: [correct], timeout: 5)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        shot("04-ask-recalled", app)

        // Home shows the encouragement.
        app.buttons["homeButton"].tap()
        let recall = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "思い出せました")).firstMatch
        XCTAssertTrue(recall.waitForExistence(timeout: 5))
        shot("05-home-encouragement", app)

        // Settings (the key field stays empty on screen: it is a secure field).
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.switches["reminderToggle"].waitForExistence(timeout: 5))
        shot("06-settings", app)
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // The simulator can reach the Mac's file system (the API key is read the same way).
        let folder = repositoryRoot().appendingPathComponent("screenshots-out")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func liveKey() throws -> String {
        let keyFile = repositoryRoot().appendingPathComponent("secrets/anthropic_api_key")
        let key = (try? String(contentsOf: keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(key.isEmpty, "no local API key; screenshots skipped")
        return key
    }
}
