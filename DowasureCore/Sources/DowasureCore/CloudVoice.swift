import Foundation

/// Natural-sounding speech from Google Cloud Text-to-Speech.
/// Only the sentence to be read aloud is sent. The app falls back to the built-in iPhone voice
/// when no key is set or the request fails.
public struct CloudVoice: Sendable {
    public static let endpoint = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize")!
    public static let defaultVoiceName = "ja-JP-Chirp3-HD-Achernar"

    let apiKey: String
    let transport: HTTPTransport
    public var voiceName: String

    public init(apiKey: String, voiceName: String = CloudVoice.defaultVoiceName,
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.voiceName = voiceName
        self.transport = transport
    }

    struct RequestBody: Encodable {
        struct Input: Encodable { let text: String }
        struct Voice: Encodable { let languageCode: String; let name: String }
        struct AudioConfig: Encodable { let audioEncoding: String }
        let input: Input
        let voice: Voice
        let audioConfig: AudioConfig
    }

    struct ResponseBody: Decodable {
        let audioContent: String
    }

    func makeRequest(text: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            input: .init(text: text),
            voice: .init(languageCode: "ja-JP", name: voiceName),
            audioConfig: .init(audioEncoding: "MP3")))
        return request
    }

    /// Returns MP3 audio for the text.
    public func synthesize(_ text: String) async throws -> Data {
        let (data, http) = try await transport.send(try makeRequest(text: text))
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let audio = Data(base64Encoded: body.audioContent), !audio.isEmpty else {
            throw ClaudeError.decoding("tts response")
        }
        return audio
    }
}
