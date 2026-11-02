import SwiftUI
import SwiftData
import DowasureCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var apiKey = APIKeyStore.load()
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("APIキー") {
                SecureField("sk-ant-…", text: $apiKey)
                    .textContentType(.password)
                    .accessibilityIdentifier("apiKeyField")
                Button("保存する") {
                    message = APIKeyStore.save(apiKey) ? "保存しました。" : "保存できませんでした。"
                }
                Text("キーはこのiPhoneのキーチェーンにだけ保存されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("お試し用の記録") {
                Button("架空の記録を入れる") { loadSamples() }
                    .accessibilityIdentifier("loadSamples")
                Button("すべての記録を消す", role: .destructive) { confirmDelete = true }
            }
            if let message {
                Section { Text(message).accessibilityIdentifier("settingsMessage") }
            }
        }
        .font(.title3)
        .navigationTitle("設定")
        .confirmationDialog("すべての記録を消しますか？元に戻せません。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                do {
                    try RecordStore.deleteAll(in: context)
                    message = "記録を消しました。"
                } catch {
                    message = "消せませんでした。"
                }
            }
        }
    }

    private func loadSamples() {
        do {
            for record in SampleData.records(today: Date()) {
                try RecordStore.save(record, in: context)
            }
            message = "架空の記録を入れました。"
        } catch {
            message = "入れられませんでした。"
        }
    }
}
