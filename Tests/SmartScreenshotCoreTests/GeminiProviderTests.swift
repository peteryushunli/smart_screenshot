import Foundation
import Testing
@testable import SmartScreenshotCore

/// All Gemini tests use `MockTransport`; none needs an API key or makes a network request.
@Suite("Gemini provider")
struct GeminiProviderTests {
    static let testKey = "test-key-not-real-0000"

    func makeProvider(_ replies: [MockTransport.Reply], model: String? = nil) throws -> (GeminiNamingProvider, MockTransport, SleepRecorder) {
        let transport = MockTransport(replies)
        let sleeper = SleepRecorder()
        let configuration = try GeminiConfiguration.fromEnvironment(["GEMINI_API_KEY": Self.testKey], model: model)
        return (GeminiNamingProvider(configuration: configuration, transport: transport, sleep: sleeper.sleep), transport, sleeper)
    }

    func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Configuration

    @Test("A missing or blank GEMINI_API_KEY is a configuration error", arguments: [[:], ["GEMINI_API_KEY": ""], ["GEMINI_API_KEY": "  \n"]])
    func missingKey(environment: [String: String]) {
        #expect(throws: ConfigurationError.missingAPIKey) {
            try GeminiConfiguration.fromEnvironment(environment)
        }
        #expect(ConfigurationError.missingAPIKey.description.contains("GEMINI_API_KEY is not set"))
    }

    @Test("Model codes are validated because they become part of the URL path")
    func modelNames() throws {
        let environment = ["GEMINI_API_KEY": Self.testKey]
        #expect(try GeminiConfiguration.fromEnvironment(environment).model == "gemini-2.5-flash-lite")
        #expect(try GeminiConfiguration.fromEnvironment(environment, model: "models/gemini-3.5-flash-lite").model == "gemini-3.5-flash-lite")
        for bad in ["../evil", "gemini?key=1", "gemini 2", "", "models/"] {
            #expect(throws: ConfigurationError.invalidModelName(bad)) {
                try GeminiConfiguration.fromEnvironment(environment, model: bad)
            }
        }
    }

    @Test("The API key never appears in descriptions or dumps")
    func keyIsNeverPrinted() throws {
        let configuration = try GeminiConfiguration.fromEnvironment(["GEMINI_API_KEY": Self.testKey])
        var dumped = ""
        dump(configuration, to: &dumped)
        #expect(!dumped.contains(Self.testKey))
        #expect(!String(describing: configuration).contains(Self.testKey))
        #expect(!"\(configuration.apiKey)".contains(Self.testKey))
    }

    // MARK: Request

    @Test("Builds a generateContent request with the key in a header and a structured-output schema")
    func requestShape() throws {
        let (provider, _, _) = try makeProvider([])
        let request = try provider.makeRequest(for: pandasErrorDocument)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.testKey)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.absoluteString.contains(Self.testKey) == false)
        #expect(request.timeoutInterval == 30)

        let bodyText = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!bodyText.contains(Self.testKey))
        // Text only: no inline image data or file references.
        for imageField in ["inlineData", "inline_data", "fileData", "file_data", "image/png"] {
            #expect(!bodyText.contains(imageField))
        }

        let json = try requestJSON(request)
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["maxOutputTokens"] as? Int == 512)
        #expect(config["temperature"] == nil)
        #expect(config["thinkingConfig"] == nil)
        let schema = try #require(config["responseJsonSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let outcome = try #require(properties["outcome"] as? [String: Any])
        #expect(outcome["enum"] as? [String] == ["title", "insufficient_information"])
        #expect(schema["required"] as? [String] == ["outcome", "title"])

        let system = try #require(((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(system.contains("untrusted"))
        #expect(system.contains("insufficient_information"))

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        let userText = try #require((contents.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(userText.contains("No module named 'pandas'"))
        #expect(userText.contains("\"top\""))
        #expect(userText.contains("\"size\""))
        #expect(userText.contains("\"confidence\""))
    }

    @Test("OCR text is redacted and bounded, keeping prominent lines first")
    func boundedInput() throws {
        let configuration = try GeminiConfiguration.fromEnvironment(["GEMINI_API_KEY": Self.testKey])
        var lines = (0..<400).map { index in
            ocrLine("Line \(index) " + String(repeating: "lorem ipsum ", count: 8), top: 0.1 + Double(index) * 0.002, height: 0.01)
        }
        lines.append(ocrLine("Contact jane.doe@example.com or 4111 1111 1111 1111", top: 0.95, height: 0.01))
        lines.append(ocrLine("Prominent Heading At The Bottom", top: 0.97, height: 0.03))
        lines.append(ocrLine(String(repeating: "x", count: 1_000), top: 0.99, height: 0.01))
        let payload = GeminiWireFormat.ocrPayload(for: ocrDocument(lines), configuration: configuration)

        #expect(payload.lines.count <= configuration.maxInputLines)
        #expect(payload.lines.reduce(0) { $0 + $1.text.count } <= configuration.maxInputCharacters)
        #expect(payload.lines.allSatisfy { $0.text.count <= configuration.maxLineCharacters })
        #expect(payload.omittedLines == lines.count - payload.lines.count)
        #expect(payload.omittedLines > 0)
        #expect(payload.lines.contains { $0.text == "Prominent Heading At The Bottom" && $0.size == 3 })
        // The payload stays in reading order.
        #expect(payload.lines.map(\.top) == payload.lines.map(\.top).sorted())

        let small = GeminiWireFormat.ocrPayload(
            for: ocrDocument([ocrLine("Contact jane.doe@example.com or 4111 1111 1111 1111", top: 0.5)]),
            configuration: configuration
        )
        #expect(small.lines.map(\.text) == ["Contact [email] or [number]"])
        #expect(small.omittedLines == 0)
    }

    // MARK: Responses

    @Test("A structured title is returned with token usage")
    func titleResponse() async throws {
        let (provider, transport, _) = try makeProvider([.status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module")))])
        let result = try await provider.proposeTitle(for: pandasErrorDocument)
        #expect(result.outcome == .title("Python missing pandas module"))
        #expect(result.usage == TokenUsage(promptTokens: 120, outputTokens: 9, totalTokens: 129))
        #expect(await transport.requests.count == 1)
    }

    @Test("An explicit insufficient-information outcome is not an error")
    func insufficientResponse() async throws {
        let (provider, _, _) = try makeProvider([.status(200, body: geminiBody(answer: insufficientAnswer))])
        let result = try await provider.proposeTitle(for: pandasErrorDocument)
        guard case .insufficientInformation = result.outcome else {
            Issue.record("expected insufficient information, got \(result.outcome)")
            return
        }
        #expect(result.usage?.totalTokens == 129)
    }

    @Test("Thought parts are ignored")
    func thoughtParts() throws {
        let body = #"""
            {"candidates": [{"content": {"parts": [
                {"text": "Thinking about the title", "thought": true},
                {"text": "{\"outcome\": \"title\", \"title\": \"Kubernetes rollout status\"}"}
            ]}, "finishReason": "STOP"}]}
            """#
        let result = try GeminiWireFormat.parseResponse(Data(body.utf8))
        #expect(result.outcome == .title("Kubernetes rollout status"))
        #expect(result.usage == nil)
    }

    @Test("Malformed responses are errors", arguments: [
        "<html>Bad gateway</html>",
        "{}",
        #"{"candidates": []}"#,
        geminiBody(answer: nil),
        geminiBody(answer: "Sure! A good title would be: Python error"),
        geminiBody(answer: #"{"title": "Missing outcome"}"#),
        geminiBody(answer: #"{"outcome": "maybe", "title": "Unsure"}"#),
        geminiBody(answer: #"{"outcome": "title", "title": "   "}"#),
        geminiBody(answer: #"{"outcome": "title"}"#),
        geminiBody(answer: #"["outcome", "title"]"#),
    ])
    func malformedResponses(body: String) async throws {
        let (provider, _, _) = try makeProvider([.status(200, body: body)])
        let error = await #expect(throws: GeminiError.self) {
            try await provider.proposeTitle(for: pandasErrorDocument)
        }
        guard case .malformedResponse? = error else {
            Issue.record("expected a malformed-response error, got \(String(describing: error))")
            return
        }
    }

    @Test("Blocked prompts and unfinished answers are errors that keep usage")
    func blockedAndIncomplete() throws {
        let blocked = #"{"promptFeedback": {"blockReason": "SAFETY"}, "usageMetadata": {"promptTokenCount": 80, "totalTokenCount": 80}}"#
        #expect(throws: GeminiError.blocked(reason: "SAFETY", usage: TokenUsage(promptTokens: 80, totalTokens: 80))) {
            try GeminiWireFormat.parseResponse(Data(blocked.utf8))
        }
        for reason in ["MAX_TOKENS", "SAFETY", "RECITATION", "OTHER"] {
            let body = geminiBody(answer: #"{"outcome": "title", "title": "Cut off"#, finishReason: reason)
            #expect(throws: GeminiError.incomplete(finishReason: reason, usage: TokenUsage(promptTokens: 120, outputTokens: 9, totalTokens: 129))) {
                try GeminiWireFormat.parseResponse(Data(body.utf8))
            }
        }
    }

    // MARK: HTTP errors, retries, and network failures

    @Test("Client errors fail immediately with the API's message and a hint")
    func clientError() async throws {
        let (provider, transport, sleeper) = try makeProvider([
            .status(400, body: googleError(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.")),
        ])
        await #expect(throws: GeminiError.http(status: 400, message: "API key not valid. Please pass a valid API key.")) {
            try await provider.proposeTitle(for: pandasErrorDocument)
        }
        #expect(await transport.requests.count == 1)
        #expect(await sleeper.delays.isEmpty)
        #expect(GeminiError.http(status: 404, message: "not found").description.contains("--model gemini-3.5-flash-lite"))
    }

    @Test("Server errors are retried with backoff, then succeed")
    func retryThenSucceed() async throws {
        let (provider, transport, sleeper) = try makeProvider([
            .status(503, body: googleError(503, "UNAVAILABLE", "The model is overloaded.")),
            .failure(.timedOut),
            .status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module"))),
        ])
        let result = try await provider.proposeTitle(for: pandasErrorDocument)
        #expect(result.outcome == .title("Python missing pandas module"))
        #expect(await transport.requests.count == 3)
        let delays = await sleeper.delays
        #expect(delays.count == 2)
        #expect((1.0...1.25).contains(delays[0]))
        #expect((2.0...2.25).contains(delays[1]))
    }

    @Test("Retries are bounded")
    func retriesExhausted() async throws {
        let quota = googleError(429, "RESOURCE_EXHAUSTED", "Quota exceeded for requests per minute.")
        let (provider, transport, sleeper) = try makeProvider(Array(repeating: .status(429, body: quota), count: 5))
        await #expect(throws: GeminiError.http(status: 429, message: "Quota exceeded for requests per minute.")) {
            try await provider.proposeTitle(for: pandasErrorDocument)
        }
        #expect(await transport.requests.count == 3)
        #expect(await sleeper.delays.count == 2)
    }

    @Test("Server-suggested retry delays are honored only up to the cap")
    func serverRetryDelay() async throws {
        let short = googleError(429, "RESOURCE_EXHAUSTED", "Slow down.", retryDelay: "7s")
        let (provider, _, sleeper) = try makeProvider([
            .status(429, body: short),
            .status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module"))),
        ])
        _ = try await provider.proposeTitle(for: pandasErrorDocument)
        #expect(await sleeper.delays == [7])

        let long = googleError(429, "RESOURCE_EXHAUSTED", "Daily quota exceeded.", retryDelay: "3600s")
        let (patient, transport, longSleeper) = try makeProvider([.status(429, body: long), .status(429, body: long)])
        await #expect(throws: GeminiError.self) {
            try await patient.proposeTitle(for: pandasErrorDocument)
        }
        #expect(await transport.requests.count == 1)
        #expect(await longSleeper.delays.isEmpty)
    }

    @Test("Odd Retry-After values never crash or stall")
    func oddRetryAfter() async throws {
        let (provider, _, sleeper) = try makeProvider([
            .status(503, body: "", headers: ["retry-after": "-5"]),
            .status(503, body: "", headers: ["retry-after": "nan"]),
            .status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module"))),
        ])
        await #expect(throws: GeminiError.self) {
            try await provider.proposeTitle(for: pandasErrorDocument)
        }
        #expect(await sleeper.delays == [0])
    }

    @Test("Network failures become errors; offline failures are not retried")
    func networkFailures() async throws {
        let (offline, offlineTransport, _) = try makeProvider([.failure(.notConnectedToInternet)])
        let error = await #expect(throws: GeminiError.self) {
            try await offline.proposeTitle(for: pandasErrorDocument)
        }
        guard case .network(let message)? = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("-1009"))
        #expect(await offlineTransport.requests.count == 1)

        let (flaky, flakyTransport, _) = try makeProvider(Array(repeating: .failure(.timedOut), count: 5))
        await #expect(throws: GeminiError.self) {
            try await flaky.proposeTitle(for: pandasErrorDocument)
        }
        #expect(await flakyTransport.requests.count == 3)
    }

    @Test("Error messages from the server are cleaned and never echo the key")
    func errorMessageSanitizing() async throws {
        let echoed = googleError(403, "PERMISSION_DENIED", "Key \(Self.testKey) lacks access.\u{1B}[31m\nRetry later")
        let (provider, _, _) = try makeProvider([.status(403, body: echoed)])
        let error = await #expect(throws: GeminiError.self) {
            try await provider.proposeTitle(for: pandasErrorDocument)
        }
        let description = error?.description ?? ""
        #expect(!description.contains(Self.testKey))
        #expect(description.contains("Key <redacted> lacks access."))
        #expect(!description.contains("\u{1B}"))
        #expect(!description.contains("\n"))
    }
}
