import AVFoundation
import SwiftUI
import UIKit
import SwiftData
import DowasureCore

@main
struct DowasureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer
    /// True when the saved records could not be opened (the app then still starts, and says so).
    @State private var storageProblem = false

    init() {
        do {
            container = try ModelContainer(for: StoredDay.self)
        } catch {
            // Never crash at launch, and never delete the records file: keep it for a later try or repair.
            // New words go to a temporary place until the app is opened again.
            print("Cannot open the records: \(error)")
            container = try! ModelContainer(for: StoredDay.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            _storageProblem = State(initialValue: true)
        }
        #if DEBUG
        // Launch arguments used only by UI tests to start from a known state (not in the App Store build).
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-reset") || args.contains("-uitest-reset-records") {
            try? container.mainContext.delete(model: StoredDay.self)
            try? container.mainContext.save()
        }
        if args.contains("-uitest-reset") || args.contains("-uitest-reset-records") {
            RecallStore.reset()
        }
        if args.contains("-uitest-reset") {
            APIKeyStore.save("")
        }
        if args.contains("-uitest-no-voice") {
            // Tests must not use the maker's daily Gemini voice quota (directly or through the relay).
            APIKeyStore.save("", account: APIKeyStore.voiceAccount)
            UserDefaults.standard.set("device", forKey: Speaker.voiceModeKey)
        }
        if args.contains("-uitest-load-samples") {
            for record in SampleData.records(today: Date()) {
                try? RecordStore.save(record, in: container.mainContext)
            }
        }
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
                .alert("これまでの記録を開けませんでした", isPresented: $storageProblem) {
                    Button("わかりました") {}
                } message: {
                    Text("記録は消していません。iPhone を再起動してから、もう一度アプリを開いてください。それまでに話したことは、アプリを閉じると残りません。")
                }
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

    /// Green and red for words and marks on the screen's own background (not for white text on a fill).
    /// In light mode they are the colors above. On a dark background those are only 2.9 to 3.9:1, so dark
    /// mode uses lighter ones: green 7.9 and red 6.7 on the dark list rows (#1C1C1E), checked by
    /// calculation (2026-11-07). Light mode does not change.
    static let greenText = adaptive(light: (0, 122, 61), dark: (70, 200, 120))
    static let redText = adaptive(light: (196, 30, 30), dark: (255, 122, 112))

    private static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        })
    }
}

/// Error or warning text: never color alone, always with an icon and words.
struct WarningText: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.title2)
            .foregroundStyle(Palette.redText)
    }
}

/// Shared look: large text and large buttons for older users.
enum Style {
    static let bigButtonHeight: CGFloat = 120
    static let homeButtonHeight: CGFloat = 80
    /// Buttons in the bottom area of a screen (hint choices, "聞いてみる"): still large, but several must fit there.
    static let dockButtonHeight: CGFloat = 72
    /// The reading area at the top never shrinks below this, even with the largest text size.
    static let readingMinHeight: CGFloat = 140
}

struct BigButton: View {
    let title: String
    let systemImage: String
    let color: Color
    var height: CGFloat = Style.bigButtonHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title.bold())
                .wrapsForLargeText()
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// The bottom area of a screen, where every button goes (2026-11-07, 藤川さん：「iPhoneを右手で持ったときに、
/// 親指はiPhoneに対して下半分しか使えません」). The top of the screen is left for things to read.
/// It is as tall as its buttons; only when they do not fit (the largest text sizes) does it scroll.
struct ThumbDock<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 12) { content }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight > 0 ? contentHeight : .infinity)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .layoutPriority(1)
    }
}

/// Every screen other than home: large title at the top, then the things to read (scrolling),
/// and at the bottom, within reach of the thumb, the screen's buttons and a large "back to home" button
/// (instead of the small arrow in the top corner).
struct ElderScreen<Actions: View>: ViewModifier {
    let title: String
    let actions: Actions
    /// For screens whose text fields are in the reading area (settings): while the keyboard is up,
    /// the bottom area is hidden, so it does not ride up over the keyboard and cover the field and its button.
    /// (On the talk and ask screens the text field is in the bottom area, so it must stay.)
    var hidesDockWithKeyboard = false
    @Environment(\.dismiss) private var dismiss
    @State private var keyboardShown = false

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            VolumeWarning()
                .padding(.horizontal, 24)
                .padding(.top, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .frame(minHeight: Style.readingMinHeight)
            if !(hidesDockWithKeyboard && keyboardShown) {
            ThumbDock {
                actions
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
                .accessibilityIdentifier("homeButton")
            }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
    }
}

extension View {
    func elderScreen(_ title: String, hidesDockWithKeyboard: Bool = false) -> some View {
        modifier(ElderScreen(title: title, actions: EmptyView(), hidesDockWithKeyboard: hidesDockWithKeyboard))
    }

    /// `actions` are the screen's buttons; they are placed in the bottom half, above "ホームにもどる".
    func elderScreen<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        modifier(ElderScreen(title: title, actions: actions()))
    }

    /// With the largest text sizes, labels wrap onto more lines instead of being cut off with "…".
    func wrapsForLargeText() -> some View {
        self.lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}
