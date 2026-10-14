import Foundation

/// Describes a naming provider for reports.
public struct ProviderInfo: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// Deterministic rules over OCR output. Not an AI summary.
        case heuristic
        /// A language model that interprets OCR output.
        case languageModel = "language-model"
    }

    /// Identifier used on the command line and in reports, e.g. "local" or "gemini".
    public var id: String
    public var kind: Kind
    public var model: String?
    /// Whether OCR text leaves this Mac.
    public var sendsTextOffDevice: Bool
    /// One-line, user-facing description of how titles are produced.
    public var summary: String

    public init(id: String, kind: Kind, model: String?, sendsTextOffDevice: Bool, summary: String) {
        self.id = id
        self.kind = kind
        self.model = model
        self.sendsTextOffDevice = sendsTextOffDevice
        self.summary = summary
    }
}

/// Token counts reported by a model provider, when available.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var thoughtsTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, outputTokens: Int? = nil, thoughtsTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.thoughtsTokens = thoughtsTokens
        self.totalTokens = totalTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        return TokenUsage(
            promptTokens: add(lhs.promptTokens, rhs.promptTokens),
            outputTokens: add(lhs.outputTokens, rhs.outputTokens),
            thoughtsTokens: add(lhs.thoughtsTokens, rhs.thoughtsTokens),
            totalTokens: add(lhs.totalTokens, rhs.totalTokens)
        )
    }
}

/// What a provider concluded from the OCR evidence.
public enum NamingOutcome: Sendable, Equatable {
    /// A raw title. It is sanitized and validated before it becomes part of a filename.
    case title(String)
    /// The evidence does not support a specific title; the original filename is kept.
    case insufficientInformation(reason: String)
}

public struct NamingResult: Sendable, Equatable {
    public var outcome: NamingOutcome
    public var usage: TokenUsage?

    public init(outcome: NamingOutcome, usage: TokenUsage? = nil) {
        self.outcome = outcome
        self.usage = usage
    }
}

/// Turns OCR output into a proposed title. Implementations receive text and layout only, never image pixels.
public protocol NamingProvider: Sendable {
    var info: ProviderInfo { get }
    func proposeTitle(for document: RecognizedDocument) async throws -> NamingResult
}

/// An error raised after a model already processed (and billed) the request, so usage is still reportable.
public protocol TokenUsageReporting: Error {
    var usage: TokenUsage? { get }
}

extension LocalizedError where Self: CustomStringConvertible {
    /// Lets `localizedDescription` show this module's own error descriptions.
    public var errorDescription: String? { description }
}
