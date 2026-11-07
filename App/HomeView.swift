import SwiftUI

enum Route: Hashable {
    case ask, talk, settings
}

struct HomeView: View {
    @State private var path: [Route] = []
    /// Without the Claude key the app can save words but not give hints, so first-time setup is shown here.
    @State private var needsSetup = APIKeyStore.load().isEmpty
    /// "この1週間で、ご自分で3回思い出せました。" Shown only after the first time; never a "0".
    @State private var recallMessage = RecallStore.homeMessage()

    var body: some View {
        NavigationStack(path: $path) {
            // Top half: only things to read. Bottom half: the buttons, within reach of the right thumb
            // (藤川さん, 2026-11-07：「ボタンは画面の下半分にまとめておいてもらった方がいい」).
            VStack(spacing: 0) {
                // Scrolls when the user's text size is very large, so nothing is cut off.
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VolumeWarning()
                        if needsSetup {
                            setupNotice
                        }
                        if let recallMessage {
                            Label {
                                Text(recallMessage)
                            } icon: {
                                Image(systemName: "star.fill").foregroundStyle(Palette.green)
                            }
                                .font(.title2.bold())
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Palette.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("recallMessage")
                        }
                        Text("このアプリは暮らしの助けです。医療や診断は行いません。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(24)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(minHeight: Style.readingMinHeight)

                ThumbDock {
                    BigButton(title: "あれ、何だっけ？", systemImage: "questionmark.bubble", color: Palette.orange) {
                        path.append(.ask)
                    }
                    .accessibilityIdentifier("askButton")
                    BigButton(title: "覚えておくことを話す", systemImage: "square.and.pencil", color: .indigo) {
                        path.append(.talk)
                    }
                    .accessibilityIdentifier("talkButton")
                    // Before the key is saved, the same button reads "準備をする" (one button, not two, to the same place).
                    Button {
                        path.append(.settings)
                    } label: {
                        Label(needsSetup ? "準備をする（設定）" : "設定", systemImage: "gearshape.fill")
                            .font(.title2.bold())
                            .wrapsForLargeText()
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .navigationTitle("ど忘れ相棒")
            .onAppear {
                needsSetup = APIKeyStore.load().isEmpty
                recallMessage = RecallStore.homeMessage()
            }
            .onChange(of: path) { _, newPath in
                // Back on the home screen (e.g. after saving the key in settings): check again.
                if newPath.isEmpty {
                    needsSetup = APIKeyStore.load().isEmpty
                    recallMessage = RecallStore.homeMessage()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .ask: AskView()
                case .talk: TalkView()
                case .settings: SettingsView()
                }
            }
        }
        .onChange(of: router.openTalk, initial: true) { _, open in
            guard open else { return }
            router.openTalk = false
            path = [.talk]
        }
        .onChange(of: router.openAsk, initial: true) { _, open in
            guard open else { return }
            router.openAsk = false
            path = [.ask]
        }
    }

    private var router: AppRouter { AppRouter.shared }

    /// Shown until the key is saved: what is missing and who should do it. The button to do it is at the bottom.
    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("はじめの準備がまだです", systemImage: "info.circle.fill")
                .font(.title2.bold())
            Text("話したことは覚えられますが、ヒントを出すには準備が必要です。ご家族の方は、下の「準備をする（設定）」から設定してください。")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("setupNotice")
    }
}
