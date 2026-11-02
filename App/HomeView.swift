import SwiftUI

enum Route: Hashable {
    case ask, talk, settings
}

struct HomeView: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 28) {
                Spacer()
                BigButton(title: "あれ、何だっけ？", systemImage: "questionmark.bubble", color: .orange) {
                    path.append(.ask)
                }
                .accessibilityIdentifier("askButton")
                BigButton(title: "今日のことを話す", systemImage: "moon.stars", color: .indigo) {
                    path.append(.talk)
                }
                .accessibilityIdentifier("talkButton")
                Spacer()
                Text("このアプリは暮らしの助けです。医療や診断は行いません。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    path.append(.settings)
                } label: {
                    Label("設定", systemImage: "gearshape.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("settingsButton")
            }
            .padding(24)
            .navigationTitle("ど忘れ相棒")
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
    }

    private var router: AppRouter { AppRouter.shared }
}
