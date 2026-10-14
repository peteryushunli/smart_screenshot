import Foundation

/// Wraps the API key so `print`, `dump`, and string interpolation never reveal it.
public struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingAPIKey
    case invalidModelName(String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            """
            \(GeminiConfiguration.apiKeyEnvironmentVariable) is not set. Create a key at \
            https://aistudio.google.com/apikey, then run `export \(GeminiConfiguration.apiKeyEnvironmentVariable)=<your key>` \
            in this shell. Use --provider local to work offline without a key.
            """
        case .invalidModelName(let name):
            "invalid Gemini model name \"\(name)\"; expected a model code such as \(GeminiConfiguration.defaultModel)"
        }
    }
}

public struct GeminiConfiguration: Sendable {
    public static let defaultModel = "gemini-2.5-flash-lite"
    /// Google limits 2.5 models to keys that used them before; this is its suggested replacement for new projects.
    public static let suggestedAlternativeModel = "gemini-3.5-flash-lite"
    public static let apiKeyEnvironmentVariable = "GEMINI_API_KEY"

    public var apiKey: APIKey
    public var model: String
    /// Timeout for each attempt.
    public var requestTimeout: TimeInterval = 30
    /// Total attempts per screenshot, including the first.
    public var maxAttempts = 3
    /// A server-requested wait longer than this is not honored; the file is reported as an error instead.
    public var maxRetryDelay: TimeInterval = 20
    /// Output budget. On models that think by default it includes thinking tokens; the default model does not think.
    public var maxOutputTokens = 512
    /// Input budget per screenshot.
    public var maxInputLines = 150
    public var maxInputCharacters = 8_000
    public var maxLineCharacters = 300

    public init(apiKey: APIKey, model: String = defaultModel) throws {
        self.apiKey = apiKey
        self.model = try Self.validatedModelName(model)
    }

    /// Reads the key from `GEMINI_API_KEY`. The key is never written anywhere.
    public static func fromEnvironment(_ environment: [String: String], model: String? = nil) throws -> GeminiConfiguration {
        let key = environment[apiKeyEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw ConfigurationError.missingAPIKey }
        return try GeminiConfiguration(apiKey: APIKey(key), model: model ?? defaultModel)
    }

    /// The model code becomes part of the request path, so only plain model codes are accepted.
    static func validatedModelName(_ name: String) throws -> String {
        let code = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        guard code.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._\-]{0,99}/#) != nil else {
            throw ConfigurationError.invalidModelName(name)
        }
        return code
    }

    var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }
}

public enum GeminiError: Error, Equatable, CustomStringConvertible, LocalizedError, TokenUsageReporting {
    case network(String)
    case http(status: Int, message: String)
    case blocked(reason: String, usage: TokenUsage?)
    case incomplete(finishReason: String, usage: TokenUsage?)
    case malformedResponse(String, usage: TokenUsage?)

    public var usage: TokenUsage? {
        switch self {
        case .network, .http: nil
        case .blocked(_, let usage), .incomplete(_, let usage), .malformedResponse(_, let usage): usage
        }
    }

    public var description: String {
        switch self {
        case .network(let message):
            return "network error contacting the Gemini API: \(message)"
        case .http(let status, let message):
            return "Gemini API returned HTTP \(status): \(message)\(Self.hint(status: status, message: message))"
        case .blocked(let reason, _):
            return "Gemini declined to process the OCR text (block reason \(reason))"
        case .incomplete(let finishReason, _):
            if finishReason == "MAX_TOKENS" {
                return "the Gemini response hit the output token limit before finishing"
            }
            return "Gemini stopped without a usable answer (finish reason \(finishReason))"
        case .malformedResponse(let detail, _):
            return "malformed Gemini response: \(detail)"
        }
    }

    private static func hint(status: Int, message: String) -> String {
        let keyHint = "check that GEMINI_API_KEY is valid and restricted to the Gemini API"
        let modelHint = "the model may not be available to this key; try --model \(GeminiConfiguration.suggestedAlternativeModel)"
        switch status {
        case 400 where message.localizedCaseInsensitiveContains("API key"), 401:
            return " (\(keyHint))"
        case 403:
            return " (\(keyHint); \(modelHint))"
        case 404:
            return " (\(modelHint))"
        case 429:
            return " (rate limit or quota reached; wait and retry, or process fewer files)"
        default:
            return ""
        }
    }
}

/// Names screenshots with Gemini `generateContent`, sending OCR text and layout only.
public struct GeminiNamingProvider: NamingProvider {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    /// Transient transport failures. Offline and DNS failures are not retried because they rarely recover in seconds.
    static let retryableURLErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost]

    public let info: ProviderInfo
    let configuration: GeminiConfiguration
    let transport: any HTTPTransport
    let sleep: Sleep

    public init(configuration: GeminiConfiguration, transport: (any HTTPTransport)? = nil, sleep: Sleep? = nil) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionTransport(timeout: configuration.requestTimeout)
        self.sleep = sleep ?? { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
        info = ProviderInfo(
            id: "gemini",
            kind: .languageModel,
            model: configuration.model,
            sendsTextOffDevice: true,
            summary: "OCR runs on-device; extracted text and layout (never image pixels) are sent to the Gemini API"
        )
    }

    public func proposeTitle(for document: RecognizedDocument) async throws -> NamingResult {
        let request = try makeRequest(for: document)
        let response = try await sendWithRetries(request)
        return try GeminiWireFormat.parseResponse(response.body)
    }

    func makeRequest(for document: RecognizedDocument) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A header rather than a query parameter, so the key never appears in URLs or URL error messages.
        request.setValue(configuration.apiKey.value, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try GeminiWireFormat.requestBody(for: document, configuration: configuration)
        return request
    }

    /// Retries transient failures with exponential backoff and jitter, honoring server-suggested delays up to
    /// `maxRetryDelay`. Other client errors fail immediately.
    func sendWithRetries(_ request: URLRequest) async throws -> HTTPResponse {
        var attempt = 1
        while true {
            let delay: TimeInterval
            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    return response
                }
                let error = GeminiError.http(status: response.statusCode, message: errorMessage(from: response))
                guard Self.retryableStatusCodes.contains(response.statusCode),
                      attempt < configuration.maxAttempts,
                      let wait = retryDelay(after: response, attempt: attempt)
                else {
                    throw error
                }
                delay = wait
            } catch let error as URLError {
                guard Self.retryableURLErrors.contains(error.code), attempt < configuration.maxAttempts else {
                    throw GeminiError.network("\(error.localizedDescription) (URLError \(error.code.rawValue))")
                }
                delay = backoff(attempt: attempt)
            }
            try await sleep(delay)
            attempt += 1
        }
    }

    func backoff(attempt: Int) -> TimeInterval {
        min(configuration.maxRetryDelay, pow(2, Double(attempt - 1))) + Double.random(in: 0...0.25)
    }

    /// Returns nil when the server asks for a longer wait than this tool is willing to spend.
    func retryDelay(after response: HTTPResponse, attempt: Int) -> TimeInterval? {
        let suggested = response.headers["retry-after"].flatMap { TimeInterval($0) }
            ?? GeminiWireFormat.retryDelay(fromErrorBody: response.body)
        guard let suggested else { return backoff(attempt: attempt) }
        guard suggested.isFinite, suggested <= configuration.maxRetryDelay else { return nil }
        return max(0, suggested)
    }

    /// Extracts the API's error message, stripped of control characters, shortened, and with the key redacted.
    func errorMessage(from response: HTTPResponse) -> String {
        let message = GeminiWireFormat.errorMessage(fromErrorBody: response.body)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        let cleaned = message
            .replacingOccurrences(of: configuration.apiKey.value, with: "<redacted>")
            .unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }
}
