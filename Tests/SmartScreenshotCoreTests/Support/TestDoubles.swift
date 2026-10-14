import Foundation
@testable import SmartScreenshotCore

/// Replays canned HTTP replies or transport failures, and records every request. Never touches the network.
actor MockTransport: HTTPTransport {
    enum Reply: Sendable {
        case status(Int, body: String, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case .status(let code, let body, let headers):
            return HTTPResponse(statusCode: code, headers: headers, body: Data(body.utf8))
        case .failure(let code):
            throw URLError(code)
        }
    }
}

/// Records requested retry delays instead of sleeping.
actor SleepRecorder {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }

    nonisolated var sleep: GeminiNamingProvider.Sleep {
        { [self] delay in await record(delay) }
    }
}

/// Returns canned OCR documents by filename, so CLI tests can exercise providers without Vision.
struct StubRecognizer: TextRecognizing {
    var documents: [String: RecognizedDocument]

    func recognizeText(in fileURL: URL) throws -> RecognizedDocument {
        guard let document = documents[fileURL.lastPathComponent] else { throw TextRecognitionError.undecodableImage }
        return document
    }
}

/// A provider that returns a fixed result (or error) and counts calls.
actor SpyProvider: NamingProvider {
    nonisolated let info: ProviderInfo
    private let result: Result<NamingResult, GeminiError>
    private(set) var callCount = 0

    init(kind: ProviderInfo.Kind = .languageModel, result: Result<NamingResult, GeminiError>) {
        info = ProviderInfo(id: "spy", kind: kind, model: nil, sendsTextOffDevice: false, summary: "test double")
        self.result = result
    }

    func proposeTitle(for document: RecognizedDocument) async throws -> NamingResult {
        callCount += 1
        return try result.get()
    }
}

/// Captures CLI output.
final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = ""
    private var standardError = ""

    var stdout: String { locked { standardOutput } }
    var stderr: String { locked { standardError } }

    var output: SmartScreenshotCLI.Output {
        SmartScreenshotCLI.Output(
            write: { text in self.locked { self.standardOutput += text } },
            writeError: { text in self.locked { self.standardError += text } }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A unique temporary folder; call `remove()` when done.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartScreenshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    @discardableResult
    func write(_ contents: String, to name: String) throws -> URL {
        let fileURL = file(name)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every file below the folder (including hidden and nested files), keyed by relative path.
    func snapshot() throws -> [String: Data] {
        var contents: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count))
            contents[relative] = try Data(contentsOf: fileURL)
        }
        return contents
    }
}

// MARK: - Builders

func ocrLine(
    _ text: String,
    top: Double,
    left: Double = 0.05,
    height: Double = 0.03,
    width: Double = 0.5,
    confidence: Double = 1
) -> RecognizedLine {
    RecognizedLine(
        text: text,
        confidence: confidence,
        boundingBox: NormalizedRect(x: left, y: top, width: width, height: height)
    )
}

func ocrDocument(_ lines: [RecognizedLine], width: Int = 1200, height: Int = 800) -> RecognizedDocument {
    RecognizedDocument(imageWidth: width, imageHeight: height, lines: lines)
}

/// A terminal-style screenshot: uniform text, no heading.
let pandasErrorDocument = ocrDocument([
    ocrLine("$ python3 analyze.py", top: 0.05),
    ocrLine("Traceback (most recent call last):", top: 0.10),
    ocrLine("File \"analyze.py\", line 1, in <module>", top: 0.15),
    ocrLine("import pandas as pd", top: 0.20),
    ocrLine("ModuleNotFoundError: No module named 'pandas'", top: 0.25),
])

/// A `generateContent` response body whose model text is `answer`.
func geminiBody(
    answer: String?,
    finishReason: String? = "STOP",
    promptTokens: Int = 120,
    outputTokens: Int = 9
) -> String {
    var candidate: [String: Any] = ["index": 0]
    if let answer {
        candidate["content"] = ["role": "model", "parts": [["text": answer]]]
    }
    if let finishReason {
        candidate["finishReason"] = finishReason
    }
    let body: [String: Any] = [
        "candidates": [candidate],
        "usageMetadata": [
            "promptTokenCount": promptTokens,
            "candidatesTokenCount": outputTokens,
            "totalTokenCount": promptTokens + outputTokens,
        ],
        "modelVersion": "gemini-2.5-flash-lite",
        "responseId": "test-response",
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
}

func titleAnswer(_ title: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["outcome": "title", "title": title]), as: UTF8.self)
}

let insufficientAnswer = #"{"outcome":"insufficient_information","title":""}"#

func googleError(_ status: Int, _ statusName: String, _ message: String, retryDelay: String? = nil) -> String {
    var error: [String: Any] = ["code": status, "message": message, "status": statusName]
    if let retryDelay {
        error["details"] = [["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": retryDelay]]
    }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["error": error]), as: UTF8.self)
}

func jsonObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    return object
}

let utc = TimeZone(identifier: "UTC")!
