import Foundation

public struct ProposeOptions: Sendable, Equatable {
    public enum Provider: String, Sendable, CaseIterable {
        case local, gemini
    }

    public enum Format: String, Sendable, CaseIterable {
        case text, json
    }

    public var path: String
    public var provider: Provider = .local
    public var format: Format = .text
    public var model: String?

    public init(path: String, provider: Provider = .local, format: Format = .text, model: String? = nil) {
        self.path = path
        self.provider = provider
        self.format = format
        self.model = model
    }
}

public enum Command: Sendable, Equatable {
    case propose(ProposeOptions)
    case help
    case version
}

public struct UsageError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A small parser for the one subcommand this milestone needs; avoids a third-party dependency.
public enum CommandLineParser {
    public static let usage = """
        USAGE: smart-screenshot propose <path> [--provider local|gemini] [--format text|json] [--model <name>]

        Proposes descriptive filenames for screenshots. Never renames, moves, or modifies any file.

        ARGUMENTS:
          <path>               An image file, or a folder whose immediate children are processed.
                               Supported: PNG, JPEG, HEIC/HEIF.

        OPTIONS:
          --provider <name>    local   On-device OCR plus a heading heuristic. No network. (default)
                               gemini  On-device OCR, then the extracted text and layout (never the
                                       image) are sent to the Gemini API. Requires GEMINI_API_KEY.
          --format <name>      text (default) or json.
          --model <name>       Gemini model code (default: \(GeminiConfiguration.defaultModel)). Gemini only.
          -h, --help           Show this help.
          --version            Show the version.

        EXIT STATUS:
          0  every file was processed (proposed or skipped)
          1  at least one file failed; the others were still processed
          2  invalid usage or configuration; nothing was processed
        """

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError("missing command; expected `propose`") }
        switch first {
        case "-h", "--help", "help":
            return .help
        case "--version":
            return .version
        case "propose":
            return try parsePropose(Array(arguments.dropFirst()))
        default:
            throw UsageError("unknown command `\(first)`; expected `propose`")
        }
    }

    private static func parsePropose(_ arguments: [String]) throws -> Command {
        var path: String?
        var provider = ProposeOptions.Provider.local
        var format = ProposeOptions.Format.text
        var model: String?
        var remaining = arguments[...]
        var acceptsOptions = true

        while let argument = remaining.popFirst() {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
                continue
            }
            if acceptsOptions, argument == "-h" || argument == "--help" {
                return .help
            }
            if acceptsOptions, argument.hasPrefix("-") {
                // Accept both `--name value` and `--name=value`.
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                guard ["--provider", "--format", "--model"].contains(name) else {
                    throw UsageError("unknown option `\(name)`")
                }
                guard let value = parts.count == 2 ? parts[1] : remaining.popFirst(), !value.isEmpty else {
                    throw UsageError("option `\(name)` requires a value")
                }
                switch name {
                case "--provider":
                    guard let parsed = ProposeOptions.Provider(rawValue: value) else {
                        throw UsageError("unknown provider `\(value)`; expected local or gemini")
                    }
                    provider = parsed
                case "--format":
                    guard let parsed = ProposeOptions.Format(rawValue: value) else {
                        throw UsageError("unknown format `\(value)`; expected text or json")
                    }
                    format = parsed
                default:
                    model = value
                }
                continue
            }
            if let existing = path {
                throw UsageError("expected one path, got `\(existing)` and `\(argument)`")
            }
            guard !argument.isEmpty else { throw UsageError("the path is empty") }
            path = argument
        }

        guard let path else { throw UsageError("missing <path> to an image file or folder") }
        if model != nil, provider != .gemini {
            throw UsageError("--model is only used with --provider gemini")
        }
        return .propose(ProposeOptions(path: path, provider: provider, format: format, model: model))
    }
}
