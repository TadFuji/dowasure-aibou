import AVFoundation
import SwiftUI
import SwiftData
import DowasureCore

/// Settings. Items the user changes (reminder, voice) come first in large type;
/// one-time setup for family or developers (API key, sample records) is folded away below.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var apiKey = APIKeyStore.load()
    @State private var keyMessage: String?
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var showSetup = false
    @State private var voiceKey = APIKeyStore.load(account: APIKeyStore.voiceAccount)
    @State private var voiceKeyMessage: String?
    @AppStorage(Speaker.cloudVoiceKey) private var cloudVoiceName = CloudVoice.defaultVoiceName
    private var hasCloudVoiceKey: Bool { !voiceKey.isEmpty && voiceKeyMessage != "保存できませんでした。" }
    @AppStorage("speechSpeed") private var speechSpeed = "slow"
    @AppStorage(Speaker.voiceKey) private var voiceIdentifier = ""
    @AppStorage(EveningReminder.enabledKey) private var reminderEnabled = false
    @AppStorage(EveningReminder.hourKey) private var reminderHour = 20
    @AppStorage(EveningReminder.minuteKey) private var reminderMinute = 0
    @State private var reminderMessage: String?
    @State private var reminderDenied = false

    private let voices = Speaker.japaneseVoices

    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: reminderHour, minute: reminderMinute)) ?? Date()
        } set: { newValue in
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = c.hour ?? 20
            reminderMinute = c.minute ?? 0
            if reminderEnabled { Task { await applyReminder() } }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("毎晩お知らせする", isOn: $reminderEnabled)
                    .font(.title2.bold())
                    .accessibilityIdentifier("reminderToggle")
                    .onChange(of: reminderEnabled) { _, _ in Task { await applyReminder() } }
                DatePicker("時刻", selection: reminderTime, displayedComponents: .hourAndMinute)
                    .font(.title2)
                    .disabled(!reminderEnabled)
                if let reminderMessage {
                    Text(reminderMessage).font(.title3).accessibilityIdentifier("reminderMessage")
                }
            } header: {
                Text("お知らせ").font(.title3.bold())
            }

            Section {
                if hasCloudVoiceKey {
                    ForEach(CloudVoice.voices, id: \.name) { item in
                        Button {
                            cloudVoiceName = item.name
                            Speaker.shared.say("今日も一日、おつかれさまでした。")
                        } label: {
                            HStack {
                                Text(item.label).font(.title2)
                                Spacer()
                                if item.name == cloudVoiceName {
                                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } else {
                ForEach(voices, id: \.identifier) { voice in
                    Button {
                        voiceIdentifier = voice.identifier
                        Speaker.shared.say("今日も一日、おつかれさまでした。")
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(voice.name).font(.title2)
                                Text((voice.gender == .male ? "男性・" : voice.gender == .female ? "女性・" : "") + Self.qualityLabel(voice.quality))
                                    .font(.body).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if voice.identifier == currentVoiceID {
                                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                }
                Picker("速さ", selection: $speechSpeed) {
                    Text("ゆっくり").tag("slow")
                    Text("ふつう").tag("normal")
                }
                .pickerStyle(.segmented)
                Text("押すと、その声で読み上げます。")
                    .font(.body).foregroundStyle(.secondary)
            } header: {
                Text("声").font(.title3.bold())
            }

            Section {
                DisclosureGroup(isExpanded: $showSetup) {
                    SecureField("APIキー（sk-ant-…）", text: $apiKey)
                        .textContentType(.password)
                        .accessibilityIdentifier("apiKeyField")
                    Button("APIキーを保存する") {
                        keyMessage = APIKeyStore.save(apiKey) ? "保存しました。" : "保存できませんでした。"
                    }
                    .accessibilityIdentifier("saveKeyButton")
                    if let keyMessage {
                        Label(keyMessage, systemImage: keyMessage == "保存しました。" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(keyMessage == "保存しました。" ? .green : .red)
                            .accessibilityIdentifier("keyMessage")
                    }
                    SecureField("自然な声のキー（Google AI Studio）", text: $voiceKey)
                        .textContentType(.password)
                    Button("自然な声のキーを保存する") {
                        voiceKeyMessage = APIKeyStore.save(voiceKey, account: APIKeyStore.voiceAccount) ? "保存しました。" : "保存できませんでした。"
                        if voiceKeyMessage == "保存しました。" { Speaker.shared.say("今日も一日、おつかれさまでした。") }
                    }
                    if let voiceKeyMessage {
                        Text(voiceKeyMessage).foregroundStyle(voiceKeyMessage == "保存しました。" ? .green : .red)
                    }
                    Button("架空の記録を入れる") { loadSamples() }
                        .accessibilityIdentifier("loadSamples")
                    Button("すべての記録を消す", role: .destructive) { confirmDelete = true }
                    if let message {
                        Text(message).accessibilityIdentifier("settingsMessage")
                    }
                } label: {
                    Text("はじめの準備（ご家族向け）").font(.title3)
                }
                .accessibilityIdentifier("setupGroup")
            }
        }
        .font(.title3)
        .elderScreen("設定")
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
        .onAppear {
            // Open the setup items until a key is saved, so the first-time setup is easy to find.
            if apiKey.isEmpty { showSetup = true }
        }
    }

    private var currentVoiceID: String {
        voiceIdentifier.isEmpty ? (Speaker.shared.voice?.identifier ?? "") : voiceIdentifier
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "とても自然"
        case .enhanced: "高品質"
        default: "標準"
        }
    }

    private func applyReminder() async {
        guard reminderEnabled else {
            EveningReminder.cancel()
            if !reminderDenied { reminderMessage = "お知らせを止めました。" }
            reminderDenied = false
            return
        }
        if await EveningReminder.schedule(hour: reminderHour, minute: reminderMinute) {
            reminderMessage = String(format: "毎晩 %d時%02d分 にお知らせします。", reminderHour, reminderMinute)
        } else {
            // Turning the switch back off triggers this function again; keep this message.
            reminderDenied = true
            reminderEnabled = false
            reminderMessage = "通知が許可されていません。設定アプリ →「ど忘れ相棒」→ 通知 で許可してください。"
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
