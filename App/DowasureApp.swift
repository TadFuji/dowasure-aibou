import AVFoundation
import SwiftUI
import SwiftData
import DowasureCore

@main
struct DowasureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: StoredDay.self)
        // Launch arguments used only by UI tests to start from a known state.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-reset") || args.contains("-uitest-reset-records") {
            try? container.mainContext.delete(model: StoredDay.self)
            try? container.mainContext.save()
        }
        if args.contains("-uitest-reset") {
            APIKeyStore.save("")
        }
        if args.contains("-uitest-no-voice") {
            // Tests must not use the maker's daily Gemini voice quota.
            APIKeyStore.save("", account: APIKeyStore.voiceAccount)
        }
        if args.contains("-uitest-load-samples") {
            for record in SampleData.records(today: Date()) {
                try? RecordStore.save(record, in: container.mainContext)
            }
        }
        #if DEBUG
        // Lists the Japanese voices this device offers to apps (checked when choosing voices).
        for v in AVSpeechSynthesisVoice.speechVoices() where v.language == "ja-JP" {
            print("VOICE \(v.name) | \(v.identifier) | quality=\(v.quality.rawValue) | gender=\(v.gender.rawValue)")
        }
        // Speaks one sentence at launch to check which voice path works on a real device.
        if args.contains("-voice-selftest") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                Speaker.shared.startWaitingTone()
                try? await Task.sleep(for: .seconds(1))
                await Speaker.shared.sayAndWait("午後は、どこかへお出かけになりましたか？")
                Speaker.trace("selftest: done")
            }
        }
        // Live UI tests hand the key over from the developer's local secrets file.
        if let key = ProcessInfo.processInfo.environment["DOWASURE_UITEST_API_KEY"], !key.isEmpty {
            APIKeyStore.save(key)
        }
        if let key = ProcessInfo.processInfo.environment["DOWASURE_UITEST_VOICE_KEY"], !key.isEmpty {
            APIKeyStore.save(key, account: APIKeyStore.voiceAccount)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .task { Speaker.shared.prewarm() }
        }
        .modelContainer(container)
    }
}

/// Colors with white text at a contrast ratio of 4.5:1 or more (WCAG AA), checked by calculation:
/// orange 5.3, green 5.5, red 5.9. The system orange and green are only about 2.2 with white.
enum Palette {
    static let orange = Color(red: 178 / 255, green: 77 / 255, blue: 0)
    static let green = Color(red: 0, green: 122 / 255, blue: 61 / 255)
    static let red = Color(red: 196 / 255, green: 30 / 255, blue: 30 / 255)
}

/// Error or warning text: never color alone, always with an icon and words.
struct WarningText: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.title2)
            .foregroundStyle(Palette.red)
    }
}

/// Shared look: large text and large buttons for older users.
enum Style {
    static let bigButtonHeight: CGFloat = 120
    static let homeButtonHeight: CGFloat = 80
}

struct BigButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title.bold())
                .wrapsForLargeText()
                .frame(maxWidth: .infinity, minHeight: Style.bigButtonHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// Every screen other than home: large title at the top, and a large "back to home" button
/// at the bottom instead of the small arrow in the corner.
struct ElderScreen: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            content
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Button {
                Speaker.shared.stopEverything()
                dismiss()
            } label: {
                Label("ホームにもどる", systemImage: "house.fill")
                    .font(.title.bold())
                    .wrapsForLargeText()
                    .frame(maxWidth: .infinity, minHeight: Style.homeButtonHeight)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .background(.background)
            .accessibilityIdentifier("homeButton")
        }
    }
}

extension View {
    func elderScreen(_ title: String) -> some View { modifier(ElderScreen(title: title)) }

    /// With the largest text sizes, labels wrap onto more lines instead of being cut off with "…".
    func wrapsForLargeText() -> some View {
        self.lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}
