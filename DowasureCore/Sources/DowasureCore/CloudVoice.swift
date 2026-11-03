import Foundation

/// Natural-sounding speech from the Gemini API text-to-speech model, using a Google AI Studio key.
/// Only the sentence to be read aloud is sent. The app falls back to the built-in iPhone voice
/// when no key is set or the request fails.
public struct CloudVoice: Sendable {
    public static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    public static let model = "gemini-3.8-flash-lite-tts"
    /// Used when the main model hits its daily limit (Tier 1: 100 requests per day per model, 2026-11-03).
    public static let fallbackModel = "gemini-3.8-flash-tts"
    /// Prebuilt voices described as warm or gentle, suited to an evening conversation.
    public static let voices: [(name: String, label: String)] = [
        ("Sulafat", "あたたかい声"),
        ("Vindemiatrix", "やさしい声"),
        ("Achernar", "やわらかい声"),
    ]
    public static let defaultVoiceName = "Sulafat"

    let apiKey: String
    let transport: HTTPTransport
    public var voiceName: String
    public var model: String = CloudVoice.model
    /// Delivery hint, e.g. speaking slowly for older listeners.
    public var style: String

    public init(apiKey: String, voiceName: String = CloudVoice.defaultVoiceName,
                style: String = "calm, kind and warm, speaking slowly and clearly",
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.voiceName = voiceName
        self.style = style
        self.transport = transport
    }

    func makeRequest(text: String, stream: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var annotation: [String: JSONValue] = ["type": "speech_metadata"]
        if !style.isEmpty { annotation["style"] = .string(style) }
        let body: JSONValue = [
            "model": .string(model),
            "input": [[
                "type": "user_input",
                "content": [[
                    "type": "text",
                    "text": .string(text),
                    "annotations": [.object(annotation)],
                ]],
            ]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": .string(voiceName)]]],
            "stream": .bool(stream),
        ]
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Streaming version: yields raw 16-bit PCM (24 kHz, mono) chunks as they arrive,
    /// so playback can start about 2 seconds earlier than waiting for the whole file.
    public func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(text: text, stream: true)
                    request.timeoutInterval = 30
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ClaudeError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        if let chunk = Self.audioChunk(fromSSELine: line) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Extracts audio bytes from one server-sent-events line such as
    /// `data: {"index":0,"delta":{"data":"<base64>"},"event_type":"step.delta"}`.
    static func audioChunk(fromSSELine line: String) -> Data? {
        guard line.hasPrefix("data:") else { return nil }
        struct Event: Decodable {
            struct Delta: Decodable { let data: String? }
            let event_type: String?
            let delta: Delta?
        }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(json.utf8)),
              event.event_type == "step.delta",
              let b64 = event.delta?.data, let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
        return data
    }

    struct ResponseBody: Decodable {
        struct Step: Decodable {
            struct Content: Decodable {
                let type: String
                let data: String?
            }
            let type: String
            let content: [Content]?
        }
        let steps: [Step]
    }

    /// Returns WAV audio for the text.
    public func synthesize(_ text: String) async throws -> Data {
        let (data, http) = try await transport.send(try makeRequest(text: text))
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw ClaudeError.decoding("tts response")
        }
        let audio = body.steps
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .last { $0.type == "audio" }?.data
        guard let audio, let decoded = Data(base64Encoded: audio), !decoded.isEmpty else {
            throw ClaudeError.decoding("tts audio missing")
        }
        return decoded
    }
}
