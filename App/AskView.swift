import SwiftUI
import SwiftData
import DowasureCore

/// "What was it again?" Answers only from the user's own records.
struct AskView: View {
    @Environment(\.modelContext) private var context
    @State private var question = ""
    @State private var isWorking = false
    @State private var result: VerifiedAnswer?
    @State private var errorMessage: String?
    @State private var voice = VoiceInput()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("何を思い出したいですか？")
                    .font(.title.bold())
                MicButton(voice: voice) { spoken in
                    question = spoken
                    Task { await ask() }
                }
                TextField("文字で聞く（例：先週会った眼鏡の人の名前）", text: $question, axis: .vertical)
                    .font(.title2)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("askInput")
                BigButton(title: isWorking ? "探しています…" : "聞いてみる", systemImage: "magnifyingglass", color: .orange) {
                    Task { await ask() }
                }
                .disabled(isWorking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("askSubmit")

                if let errorMessage {
                    Text(errorMessage).font(.title2).foregroundStyle(.red)
                }
                if let result {
                    Text(result.displayText)
                        .font(.title.bold())
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("answerText")
                }
            }
            .padding(24)
        }
        .elderScreen("あれ、何だっけ？")
    }

    private func ask() async {
        isWorking = true
        errorMessage = nil
        result = nil
        defer { isWorking = false }
        do {
            let answerer = Answerer(client: ClaudeClient(apiKey: APIKeyStore.load()))
            let answer = try await answerer.answer(question, records: RecordStore.allRecords(context))
            result = answer
            Speaker.shared.say(answer.displayText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
