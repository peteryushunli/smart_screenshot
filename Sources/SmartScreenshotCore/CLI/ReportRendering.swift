import Foundation

/// Facts shared by the text and JSON reports.
struct ReportContext {
    var version: String
    var provider: ProviderInfo
    var selection: InputSelection
    var timeZone: TimeZone

    static let timestampNote = "Timestamps use file creation time, an approximation of capture time."

    var providerLabel: String {
        provider.model.map { "\(provider.id) (\($0))" } ?? "\(provider.id) (\(provider.kind.rawValue))"
    }
}

// MARK: - Text

enum TextReport {
    static func header(_ context: ReportContext) -> String {
        let selection = context.selection
        var input = terminalSafe(selection.root.path)
        if selection.isDirectory {
            input += " (\(count(selection.files.count, "image"))"
            if selection.ignoredEntryCount > 0 {
                input += "; \(count(selection.ignoredEntryCount, "other entry", plural: "other entries")) ignored"
            }
            input += ")"
        }
        var lines = [
            "Smart Screenshot \(context.version) — proposed names only; no files are renamed or modified.",
            "Provider:   \(context.providerLabel) — \(context.provider.summary)",
            "Input:      \(input)",
            "Timestamps: file creation time, an approximation of capture time",
        ]
        if selection.files.isEmpty {
            lines.append("\nNo supported images found (PNG, JPEG, HEIC/HEIF).")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func entry(_ proposal: FileProposal, index: Int, total: Int, context: ReportContext) -> String {
        var status = proposal.status.rawValue
        if let reason = proposal.reason {
            status += " — \(terminalSafe(reason))"
        }
        let proposed = proposal.status == .proposed
            ? terminalSafe(proposal.proposedFilename)
            : "\(terminalSafe(proposal.originalFilename)) (unchanged)"
        var provider = context.providerLabel
        if let usage = proposal.usage {
            provider += " · tokens: \(describe(usage))"
        }
        return """

            [\(index)/\(total)] \(terminalSafe(proposal.originalFilename))
              status:   \(status)
              proposed: \(proposed)
              provider: \(provider)

            """
    }

    static func footer(_ proposals: [FileProposal]) -> String {
        let counts = Summary(proposals)
        var text = "\n\(count(counts.total, "file")): \(counts.proposed) proposed, \(counts.skipped) skipped, "
            + "\(count(counts.errors, "error")). No files were modified.\n"
        if let usage = counts.usage {
            text += "Gemini tokens: \(describe(usage)).\n"
        }
        return text
    }

    private static func describe(_ usage: TokenUsage) -> String {
        var parts: [String] = []
        if let prompt = usage.promptTokens { parts.append("\(prompt) prompt") }
        if let output = usage.outputTokens { parts.append("\(output) output") }
        if let thoughts = usage.thoughtsTokens { parts.append("\(thoughts) thinking") }
        if let total = usage.totalTokens { parts.append("\(total) total") }
        return parts.isEmpty ? "not reported" : parts.joined(separator: ", ")
    }

    private static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// Filenames and server messages can contain control or bidirectional-override characters that would
    /// garble or disguise terminal output; show a replacement character instead.
    static func terminalSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .control,
                 .format where !TitleSanitizer.allowedFormatScalars.contains(scalar):
                "\u{FFFD}"
            default:
                scalar
            }
        }))
    }
}

struct Summary {
    var total: Int
    var proposed: Int
    var skipped: Int
    var errors: Int
    var usage: TokenUsage?

    init(_ proposals: [FileProposal]) {
        total = proposals.count
        proposed = proposals.filter { $0.status == .proposed }.count
        skipped = proposals.filter { $0.status == .skipped }.count
        errors = proposals.filter { $0.status == .error }.count
        let usages = proposals.compactMap(\.usage)
        usage = usages.first.map { first in usages.dropFirst().reduce(first, +) }
    }
}

// MARK: - JSON

/// The JSON report carries the same information as the text report.
struct JSONReport: Encodable {
    struct Provider: Encodable {
        var id: String
        var kind: ProviderInfo.Kind
        var model: String?
        var sendsTextOffDevice: Bool
        var description: String

        enum CodingKeys: CodingKey {
            case id, kind, model, sendsTextOffDevice, description
        }

        // Absent values are written as null so every report has the same keys.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(model, forKey: .model)
            try container.encode(sendsTextOffDevice, forKey: .sendsTextOffDevice)
            try container.encode(description, forKey: .description)
        }
    }

    struct Input: Encodable {
        var path: String
        var kind: String
        var imageCount: Int
        var ignoredEntryCount: Int
    }

    struct Result: Encodable {
        var originalFilename: String
        var proposedFilename: String
        var provider: String
        var status: FileProposal.Status
        var title: String?
        var reason: String?
        var timestamp: String?
        var timestampSource: FileTimestamp.Source?
        var ocrLineCount: Int?
        var usage: TokenUsage?

        enum CodingKeys: CodingKey {
            case originalFilename, proposedFilename, provider, status, title, reason
            case timestamp, timestampSource, ocrLineCount, usage
        }

        // Absent values are written as null so every result has the same keys.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(originalFilename, forKey: .originalFilename)
            try container.encode(proposedFilename, forKey: .proposedFilename)
            try container.encode(provider, forKey: .provider)
            try container.encode(status, forKey: .status)
            try container.encode(title, forKey: .title)
            try container.encode(reason, forKey: .reason)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(timestampSource, forKey: .timestampSource)
            try container.encode(ocrLineCount, forKey: .ocrLineCount)
            try container.encode(usage, forKey: .usage)
        }
    }

    struct Totals: Encodable {
        var total: Int
        var proposed: Int
        var skipped: Int
        var errors: Int
        var usage: TokenUsage?

        enum CodingKeys: CodingKey {
            case total, proposed, skipped, errors, usage
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(total, forKey: .total)
            try container.encode(proposed, forKey: .proposed)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(errors, forKey: .errors)
            try container.encode(usage, forKey: .usage)
        }
    }

    var tool = "smart-screenshot"
    var version: String
    var filesModified = false
    var provider: Provider
    var input: Input
    var timestampNote = ReportContext.timestampNote
    var results: [Result]
    var summary: Totals

    init(context: ReportContext, proposals: [FileProposal]) {
        version = context.version
        provider = Provider(
            id: context.provider.id,
            kind: context.provider.kind,
            model: context.provider.model,
            sendsTextOffDevice: context.provider.sendsTextOffDevice,
            description: context.provider.summary
        )
        input = Input(
            path: context.selection.root.path,
            kind: context.selection.isDirectory ? "folder" : "file",
            imageCount: context.selection.files.count,
            ignoredEntryCount: context.selection.ignoredEntryCount
        )
        let iso = ISO8601DateFormatter()
        iso.timeZone = context.timeZone
        results = proposals.map { proposal in
            Result(
                originalFilename: proposal.originalFilename,
                proposedFilename: proposal.proposedFilename,
                provider: context.provider.id,
                status: proposal.status,
                title: proposal.title,
                reason: proposal.reason,
                timestamp: proposal.timestamp.map { iso.string(from: $0.date) },
                timestampSource: proposal.timestamp?.source,
                ocrLineCount: proposal.ocrLineCount,
                usage: proposal.usage
            )
        }
        let counts = Summary(proposals)
        summary = Totals(
            total: counts.total,
            proposed: counts.proposed,
            skipped: counts.skipped,
            errors: counts.errors,
            usage: counts.usage
        )
    }
}

/// Emitted instead of a report when nothing could be processed.
struct JSONFailureReport: Encodable {
    struct Failure: Encodable {
        var kind: String
        var message: String
    }

    var tool = "smart-screenshot"
    var version: String
    var filesModified = false
    var error: Failure
}

enum JSONOutput {
    static func render(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Every field is a string, number, Boolean, or nested struct, so encoding cannot fail.
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
