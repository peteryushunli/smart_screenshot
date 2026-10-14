import Foundation

/// Command-line orchestration: parse arguments, build the provider, process each file, and report.
public enum SmartScreenshotCLI {
    public static let version = "0.1.0"

    public enum ExitCode {
        public static let success: Int32 = 0
        /// The batch finished, but at least one file failed.
        public static let fileErrors: Int32 = 1
        /// Invalid usage or configuration; nothing was processed.
        public static let usage: Int32 = 2
    }

    public struct Output: Sendable {
        public var write: @Sendable (String) -> Void
        public var writeError: @Sendable (String) -> Void

        public init(write: @escaping @Sendable (String) -> Void, writeError: @escaping @Sendable (String) -> Void) {
            self.write = write
            self.writeError = writeError
        }

        public static let standard = Output(
            write: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeError: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }

    /// Seams for tests. The live values use Vision and URLSession.
    public struct Dependencies: Sendable {
        public var recognizer: any TextRecognizing
        /// Replaces the Gemini HTTP transport; nil means URLSession.
        public var geminiTransport: (any HTTPTransport)?
        public var sleep: GeminiNamingProvider.Sleep?
        public var timeZone: TimeZone

        public init(
            recognizer: any TextRecognizing = VisionTextRecognizer(),
            geminiTransport: (any HTTPTransport)? = nil,
            sleep: GeminiNamingProvider.Sleep? = nil,
            timeZone: TimeZone = .current
        ) {
            self.recognizer = recognizer
            self.geminiTransport = geminiTransport
            self.sleep = sleep
            self.timeZone = timeZone
        }

        public static var live: Dependencies { Dependencies() }
    }

    public static func run(
        arguments: [String],
        environment: [String: String],
        output: Output = .standard,
        dependencies: Dependencies = .live
    ) async -> Int32 {
        let command: Command
        do {
            command = try CommandLineParser.parse(arguments)
        } catch {
            output.writeError("error: \(error.localizedDescription)\n\n\(CommandLineParser.usage)\n")
            return ExitCode.usage
        }
        switch command {
        case .help:
            output.write(CommandLineParser.usage + "\n")
            return ExitCode.success
        case .version:
            output.write("smart-screenshot \(version)\n")
            return ExitCode.success
        case .propose(let options):
            return await propose(options, environment: environment, output: output, dependencies: dependencies)
        }
    }

    static func propose(
        _ options: ProposeOptions,
        environment: [String: String],
        output: Output,
        dependencies: Dependencies
    ) async -> Int32 {
        let provider: any NamingProvider
        let selection: InputSelection
        do {
            provider = try makeProvider(options, environment: environment, dependencies: dependencies)
            selection = try InputCollector.collect(path: options.path)
        } catch {
            let kind = error is InputError ? "input" : "configuration"
            output.writeError("error: \(error.localizedDescription)\n")
            if options.format == .json {
                let failure = JSONFailureReport.Failure(kind: kind, message: error.localizedDescription)
                output.write(JSONOutput.render(JSONFailureReport(version: version, error: failure)))
            }
            return ExitCode.usage
        }

        let context = ReportContext(version: version, provider: provider.info, selection: selection, timeZone: dependencies.timeZone)
        let runner = ProposalRunner(
            recognizer: dependencies.recognizer,
            provider: provider,
            formatter: FilenameFormatter(timeZone: dependencies.timeZone)
        )

        if options.format == .text {
            output.write(TextReport.header(context))
        }
        var proposals: [FileProposal] = []
        for (offset, file) in selection.files.enumerated() {
            let proposal = await runner.propose(for: file)
            proposals.append(proposal)
            if options.format == .text {
                // Stream text results so long batches show progress.
                output.write(TextReport.entry(proposal, index: offset + 1, total: selection.files.count, context: context))
            }
        }

        switch options.format {
        case .text:
            output.write(TextReport.footer(proposals))
        case .json:
            output.write(JSONOutput.render(JSONReport(context: context, proposals: proposals)))
        }
        return proposals.contains { $0.status == .error } ? ExitCode.fileErrors : ExitCode.success
    }

    static func makeProvider(
        _ options: ProposeOptions,
        environment: [String: String],
        dependencies: Dependencies
    ) throws -> any NamingProvider {
        switch options.provider {
        case .local:
            return LocalHeadingProvider()
        case .gemini:
            let configuration = try GeminiConfiguration.fromEnvironment(environment, model: options.model)
            return GeminiNamingProvider(
                configuration: configuration,
                transport: dependencies.geminiTransport,
                sleep: dependencies.sleep
            )
        }
    }
}
