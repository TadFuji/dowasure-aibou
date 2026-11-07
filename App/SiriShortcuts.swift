import AppIntents

/// Siri: "ど忘れ相棒で覚えて" opens the talk screen, which then invites the words and listens.
/// The same shortcut can be put on the Action button or the lock screen from the Shortcuts app,
/// so the user does not have to find the app first ("パッと話して").
struct RememberIntent: AppIntent {
    static let title: LocalizedStringResource = "覚えておくことを話す"
    static let description = IntentDescription("ど忘れ相棒を開いて、覚えておきたいことを聞き取ります。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openTalk = true
        return .result()
    }
}

/// Siri: "ど忘れ相棒で何だっけ" opens the recall screen, which asks what to remember and listens.
struct RecallIntent: AppIntent {
    static let title: LocalizedStringResource = "あれ、何だっけ？"
    static let description = IntentDescription("ど忘れ相棒を開いて、思い出したいことを聞きます。答えの前にヒントを出します。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openAsk = true
        return .result()
    }
}

/// Phrases Siri understands without any setup by the user. Each must contain the app's name.
struct DowasureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RememberIntent(),
            phrases: [
                "\(.applicationName)で覚えて",
                "\(.applicationName)に覚えてもらう",
                "\(.applicationName)で覚えておく",
                "\(.applicationName)で覚えておくことを話す",
            ],
            shortTitle: "覚えておく",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: RecallIntent(),
            phrases: [
                "\(.applicationName)で何だっけ",
                "\(.applicationName)で思い出す",
                "\(.applicationName)で思い出したい",
            ],
            shortTitle: "あれ、何だっけ？",
            systemImageName: "questionmark.bubble"
        )
    }
}
