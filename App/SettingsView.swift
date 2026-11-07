import AVFoundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import DowasureCore

/// Settings. Items the user changes (reminder, voice) come first in large type;
/// one-time setup for family or developers (API key, sample records) is folded away below.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var apiKey = APIKeyStore.load()
    @State private var keyMessage: String?
    /// Result of trying the saved key once (so a mistyped key is found now, not when the user asks something).
    @State private var keyCheckMessage: String?
    @State private var keyCheckOK = false
    @State private var message: String?
    @State private var confirmDelete = false
    /// Read when the settings open (not on every redraw), for the export button.
    @State private var exportRecords: [DayRecord] = []
    @State private var deleteMessage: String?
    @State private var showSetup = false
    @AppStorage(Speaker.cloudVoiceKey) private var cloudVoiceName = CloudVoice.defaultVoiceName
    @AppStorage(Speaker.voiceModeKey) private var voiceMode = "cloud"
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
                // The natural voice needs no key of its own: it goes through the maker's relay (2026-11-07).
                Picker("声の種類", selection: $voiceMode) {
                    Text("自然な声").tag("cloud")
                    Text("すぐ話す声").tag("device")
                }
                .pickerStyle(.segmented)
                .onChange(of: voiceMode) { _, _ in Speaker.shared.say("今日も一日、おつかれさまでした。") }
                if voiceMode != "device" {
                    ForEach(CloudVoice.voices, id: \.name) { item in
                        Button {
                            cloudVoiceName = item.name
                            Speaker.shared.say("今日も一日、おつかれさまでした。")
                            Speaker.shared.prewarm()
                        } label: {
                            HStack {
                                Text(item.label).font(.title2)
                                Spacer()
                                if item.name == cloudVoiceName {
                                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Palette.green)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(item.name == cloudVoiceName ? .isSelected : [])
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
                                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Palette.green)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(voice.identifier == currentVoiceID ? .isSelected : [])
                }
                }
                Picker("速さ", selection: $speechSpeed) {
                    Text("ゆっくり").tag("slow")
                    Text("ふつう").tag("normal")
                }
                .pickerStyle(.segmented)
                Text("押すと、その声で読み上げます。「自然な声」は話し始めるまで2〜3秒かかります。「すぐ話す声」は iPhone の声で、待たずに話します。")
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
                        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyMessage = APIKeyStore.save(apiKey) ? "保存しました。" : "保存できませんでした。"
                        if keyMessage == "保存しました。" { Task { await checkKey() } }
                    }
                    .accessibilityIdentifier("saveKeyButton")
                    if let keyMessage {
                        Label(keyMessage, systemImage: keyMessage == "保存しました。" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(keyMessage == "保存しました。" ? Palette.green : Palette.red)
                            .accessibilityIdentifier("keyMessage")
                    }
                    if let keyCheckMessage {
                        if keyCheckOK {
                            Label(keyCheckMessage, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Palette.green)
                                .accessibilityIdentifier("keyCheckMessage")
                        } else {
                            WarningText(text: keyCheckMessage)
                                .accessibilityIdentifier("keyCheckMessage")
                        }
                    }
                    Button("架空の記録を入れる") { loadSamples() }
                        .accessibilityIdentifier("loadSamples")
                    if let message {
                        Text(message).accessibilityIdentifier("settingsMessage")
                    }
                } label: {
                    Text("はじめの準備（ご家族向け）").font(.title3)
                }
                .accessibilityIdentifier("setupGroup")
            }

            Section {
                DisclosureGroup {
                    Text("記録は、この iPhone の中だけにあります。iPhone の「iCloud バックアップ」がオンなら、機種変更の時に新しい iPhone へ移せます。念のため、ときどき書き出して控えを残してください。")
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: RecordsFile(records: exportRecords),
                              preview: SharePreview(RecordExport.fileName())) {
                        Label("記録を書き出す（\(exportRecords.count)日分）", systemImage: "square.and.arrow.up")
                            .wrapsForLargeText()
                    }
                    .disabled(exportRecords.isEmpty)
                    .accessibilityIdentifier("exportRecords")
                    DisclosureGroup {
                        Text("消すと元に戻せません。先に「記録を書き出す」で控えを残してください。")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("すべての記録を消す", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteAllRecords")
                        if let deleteMessage {
                            Text(deleteMessage).accessibilityIdentifier("deleteMessage")
                        }
                    } label: {
                        Text("記録を消す")
                    }
                    .accessibilityIdentifier("deleteGroup")
                } label: {
                    Text("記録の保管（ご家族向け）").font(.title3)
                }
                .onAppear { exportRecords = RecordStore.allRecords(context) }
                .accessibilityIdentifier("keepingGroup")
            }
        }
        .font(.title3)
        .elderScreen("設定")
        .confirmationDialog("\(exportRecords.count)日分の記録を、すべて消しますか？元に戻せません。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                do {
                    try RecordStore.deleteAll(in: context)
                    exportRecords = []
                    deleteMessage = "記録を消しました。"
                } catch {
                    deleteMessage = "消せませんでした。"
                }
            }
        }
        .onAppear {
            // Open the setup items until a key is saved, so the first-time setup is easy to find.
            if apiKey.isEmpty { showSetup = true }
        }
    }

    /// Tries the key once with a tiny request and says plainly whether it works.
    private func checkKey() async {
        keyCheckOK = true
        keyCheckMessage = "キーが使えるか確かめています…"
        let problem = await ClaudeClient(apiKey: apiKey).checkKey()
        switch problem {
        case nil:
            keyCheckOK = true
            keyCheckMessage = "キーが使えることを確かめました。"
        case .http(let status, _)? where status == 401 || status == 403:
            keyCheckOK = false
            keyCheckMessage = "このキーは使えないようです。入力し直してください。"
        case let other?:
            keyCheckOK = false
            keyCheckMessage = "いまは確かめられませんでした（保存はしました）。" + (other.errorDescription ?? "")
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

    /// The export as a .txt file, so it can be saved to Files, AirDrop'ed or mailed with a clear name.
    struct RecordsFile: Transferable {
        /// The text is made only when the user actually shares, not on every redraw.
        let records: [DayRecord]
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(exportedContentType: .plainText) { file in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(RecordExport.fileName())
                try Data(RecordExport.text(file.records).utf8).write(to: url, options: .atomic)
                return SentTransferredFile(url)
            }
        }
    }

    /// Adds the made-up records only on days that have no record yet, so real records are never replaced.
    private func loadSamples() {
        do {
            var added = 0
            var skipped = 0
            for record in SampleData.records(today: Date()) {
                if RecordStore.day(record.date, in: context) != nil {
                    skipped += 1
                    continue
                }
                try RecordStore.save(record, in: context)
                added += 1
            }
            exportRecords = RecordStore.allRecords(context)
            message = skipped == 0
                ? "架空の記録を入れました。"
                : "架空の記録を\(added)日分入れました。本物の記録がある\(skipped)日には入れていません。"
        } catch {
            message = "入れられませんでした。"
        }
    }
}
