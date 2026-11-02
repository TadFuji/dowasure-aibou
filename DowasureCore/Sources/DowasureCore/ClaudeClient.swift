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

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "APIキーが設定されていません。設定画面で入力してください。"
        case .http(let status, _) where status == 401: "APIキーが正しくないようです。設定画面で確認してください。"
        case .http(let status, _) where status == 429: "混み合っています。少し待ってから、もう一度お試しください。"
        case .http(let status, _): "通信でエラーが起きました（\(status)）。"
        case .refusal: "AIが答えを控えました。"
        case .truncated: "答えが長すぎて途中で切れました。"
        case .noText, .invalidResponse, .decoding: "AIの答えを読み取れませんでした。"
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

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    struct SystemBlock: Encodable {
        let type = "text"
        let text: String
        let cache_control: [String: String] = ["type": "ephemeral"]
    }

    struct Message: Encodable {
        let role: String
        let content: String
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
    func makeRequest(model: ClaudeModel, system: String, user: String,
                     schema: JSONValue, effort: String?, maxTokens: Int) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let body = RequestBody(
            model: model.rawValue,
            max_tokens: maxTokens,
            system: [SystemBlock(text: system)],
            messages: [Message(role: "user", content: user)],
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
        let request = try makeRequest(model: model, system: system, user: user,
                                      schema: schema, effort: effort, maxTokens: maxTokens)
        let (data, http) = try await transport.send(request)
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
}
