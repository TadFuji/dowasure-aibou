import SwiftUI
import SwiftData

@main
struct DowasureApp: App {
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
        #if DEBUG
        // Live UI tests hand the key over from the developer's local secrets file.
        if let key = ProcessInfo.processInfo.environment["DOWASURE_UITEST_API_KEY"], !key.isEmpty {
            APIKeyStore.save(key)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
    }
}

/// Shared look: large text and large buttons for older users.
enum Style {
    static let bigButtonHeight: CGFloat = 120
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
                .frame(maxWidth: .infinity, minHeight: Style.bigButtonHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
