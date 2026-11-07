import Foundation

/// Sends an HTTP request. Replaced by a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        return (data, http)
    }
}

public enum ClaudeModel: String, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
}

public enum ClaudeError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case refusal
    case truncated
    case noText
    case invalidResponse
    case decoding(String)
    /// The iPhone is not connected to the internet.
    case offline
    /// No reply in time.
    case timedOut

    /// Plain words for older users: what happened and what to do, without numbers or jargon.
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "APIキーが設定されていません。設定画面で入力してください。"
        case .http(let status, _) where status == 401 || status == 403:
            "APIキーが正しくないようです。設定画面で確認してください。"
        case .http(let status, _) where Self.isBusy(status):
            "いま混み合っています。少し待ってから、もう一度お試しください。"
        case .http: "うまく通信できませんでした。少し待ってから、もう一度お試しください。"
        case .offline: "インターネットにつながっていないようです。Wi-Fi などを確かめて、もう一度お試しください。"
        case .timedOut: "時間がかかりすぎたので、いったん止めました。もう一度お試しください。"
        case .refusal: "うまくお答えできませんでした。言い方を変えて、もう一度お試しください。"
        case .truncated, .noText, .invalidResponse, .decoding: "答えをうまく受け取れませんでした。もう一度お試しください。"
        }
    }

    /// Temporary server-side trouble (rate limit, overload, server error): worth one more try.
    static func isBusy(_ status: Int) -> Bool {
        status == 429 || status == 529 || (500...599).contains(status)
    }

    /// Turns a network error into a plain one. Cancellation is passed through untouched.
    static func from(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return ClaudeError.offline
        case .timedOut: return ClaudeError.timedOut
        default: return error
        }
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

/// Calls the Claude Messages API directly and returns structured (JSON schema) output.
public struct ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"

    let apiKey: String
    let transport: HTTPTransport
    /// Seconds to wait before the one retry after a temporary failure (0 in tests).
    let retryDelay: Double
    /// Seconds to wait for a reply before giving up (long enough for a normal answer, short enough not to feel stuck).
    public static let timeout: Double = 30

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport(), retryDelay: Double = 1.5) {
        self.apiKey = apiKey
        self.transport = transport
        self.retryDelay = retryDelay
    }

    struct SystemBlock: Encodable {
        let type = "text"
        let text: String
        let cache_control: [String: String] = ["type": "ephemeral"]
    }

    /// One turn of a conversation sent to the model.
    public struct Message: Encodable, Sendable, Equatable {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
        public static func user(_ text: String) -> Message { Message(role: "user", content: text) }
        public static func assistant(_ text: String) -> Message { Message(role: "assistant", content: text) }
    }

    struct OutputConfig: Encodable {
        struct Format: Encodable {
            let type = "json_schema"
            let schema: JSONValue
        }
        let format: Format
        let effort: String?
    }

    struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: [SystemBlock]
        let messages: [Message]
        let output_config: OutputConfig
    }

    struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
        let usage: Usage?
    }

    /// Builds the HTTP request. Separate so tests can inspect it.
    func makeRequest(model: ClaudeModel, system: String, messages: [Message],
                     schema: JSONValue, effort: String?, maxTokens: Int) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let body = RequestBody(
            model: model.rawValue,
            max_tokens: maxTokens,
            system: [SystemBlock(text: system)],
            messages: messages,
            output_config: OutputConfig(format: .init(schema: schema), effort: effort)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Sends one request and decodes the model's JSON text into `T`.
    public func structured<T: Decodable>(_ type: T.Type, model: ClaudeModel, system: String, user: String,
                                         schema: JSONValue, effort: String? = nil,
                                         maxTokens: Int = 8000) async throws -> (T, Usage?) {
        try await structured(type, model: model, system: system, messages: [.user(user)],
                             schema: schema, effort: effort, maxTokens: maxTokens)
    }

    /// Multi-turn version. `messages` must start with a user turn and alternate roles.
    public func structured<T: Decodable>(_ type: T.Type, model: ClaudeModel, system: String, messages: [Message],
                                         schema: JSONValue, effort: String? = nil,
                                         maxTokens: Int = 8000) async throws -> (T, Usage?) {
        let request = try makeRequest(model: model, system: system, messages: messages,
                                      schema: schema, effort: effort, maxTokens: maxTokens)
        let (data, http) = try await sendWithOneRetry(request)
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let response: ResponseBody
        do {
            response = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw ClaudeError.decoding("response: \(error)")
        }
        switch response.stop_reason {
        case "refusal": throw ClaudeError.refusal
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        // Thinking blocks may come first; the JSON is in the text block.
        guard let text = response.content.first(where: { $0.type == "text" })?.text else {
            throw ClaudeError.noText
        }
        do {
            return (try JSONDecoder().decode(T.self, from: Data(text.utf8)), response.usage)
        } catch {
            throw ClaudeError.decoding("text: \(error)")
        }
    }

    /// Sends the request; after a temporary failure (busy server, dropped connection) tries once more.
    /// A timeout or no internet is not retried, so the user never waits twice as long.
    func sendWithOneRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            let last = attempt == 1
            do {
                let (data, http) = try await transport.send(request)
                if !last && ClaudeError.isBusy(http.statusCode) {
                    try await Task.sleep(for: .seconds(Self.retryWait(http, default: retryDelay)))
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                let plain = ClaudeError.from(error)
                let retryableCodes: [URLError.Code] = [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                let retryable = retryableCodes.contains(error.code)
                if last || !retryable { throw plain }
                try await Task.sleep(for: .seconds(retryDelay))
            }
        }
        throw ClaudeError.invalidResponse  // not reached: the second attempt always returns or throws
    }

    /// Uses the server's "retry-after" when it is short; otherwise the default wait.
    static func retryWait(_ http: HTTPURLResponse, default fallback: Double) -> Double {
        if let value = http.value(forHTTPHeaderField: "retry-after"), let seconds = Double(value), seconds >= 0, seconds <= 5 {
            return seconds
        }
        return fallback
    }

    /// A tiny request to check that a key works (used right after saving it in settings).
    /// Returns nil when the key works, or the reason it does not.
    public func checkKey() async -> ClaudeError? {
        guard !apiKey.isEmpty else { return .missingAPIKey }
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let messages: [Message]
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        do {
            request.httpBody = try JSONEncoder().encode(Body(model: ClaudeModel.haiku.rawValue, max_tokens: 16, messages: [.user("はい")]))
            let (data, http) = try await transport.send(request)
            if (200..<300).contains(http.statusCode) { return nil }
            return .http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        } catch let error as URLError {
            return (ClaudeError.from(error) as? ClaudeError) ?? .invalidResponse
        } catch {
            return .invalidResponse
        }
    }
}
