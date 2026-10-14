import Foundation

/// The proposal for one input file. Nothing here is ever applied to the file system.
public struct FileProposal: Sendable, Equatable {
    public enum Status: String, Sendable, Codable {
        /// A new name is proposed.
        case proposed
        /// Not enough useful evidence; the original name is kept.
        case skipped
        /// Processing failed; the original name is kept.
        case error
    }

    public var originalFilename: String
    /// Equal to `originalFilename` unless `status` is `.proposed`.
    public var proposedFilename: String
    public var status: Status
    public var title: String?
    /// Why the file was skipped or failed.
    public var reason: String?
    public var timestamp: FileTimestamp?
    public var ocrLineCount: Int?
    public var usage: TokenUsage?

    public init(
        originalFilename: String,
        proposedFilename: String,
        status: Status,
        title: String? = nil,
        reason: String? = nil,
        timestamp: FileTimestamp? = nil,
        ocrLineCount: Int? = nil,
        usage: TokenUsage? = nil
    ) {
        self.originalFilename = originalFilename
        self.proposedFilename = proposedFilename
        self.status = status
        self.title = title
        self.reason = reason
        self.timestamp = timestamp
        self.ocrLineCount = ocrLineCount
        self.usage = usage
    }
}

/// Runs OCR, naming, and filename formatting for one file at a time. Every failure is captured in the
/// returned proposal, so one bad file never stops a batch.
public struct ProposalRunner: Sendable {
    public var recognizer: any TextRecognizing
    public var provider: any NamingProvider
    public var formatter: FilenameFormatter

    public init(recognizer: any TextRecognizing, provider: any NamingProvider, formatter: FilenameFormatter) {
        self.recognizer = recognizer
        self.provider = provider
        self.formatter = formatter
    }

    public func propose(for file: URL) async -> FileProposal {
        let name = file.lastPathComponent
        var proposal = FileProposal(originalFilename: name, proposedFilename: name, status: .error)

        func keepOriginal(_ status: FileProposal.Status, _ reason: String, usage: TokenUsage? = nil) -> FileProposal {
            proposal.status = status
            proposal.reason = reason
            proposal.usage = usage
            return proposal
        }

        guard InputCollector.isSupported(file) else {
            return keepOriginal(.error, "unsupported file type; expected PNG, JPEG, or HEIC/HEIF")
        }
        let timestamp: FileTimestamp
        do {
            timestamp = try FileTimestamp.read(from: file)
        } catch {
            return keepOriginal(.error, "could not read the file's dates: \(error.localizedDescription)")
        }
        proposal.timestamp = timestamp

        let document: RecognizedDocument
        do {
            document = try recognizer.recognizeText(in: file)
        } catch {
            return keepOriginal(.error, error.localizedDescription)
        }
        proposal.ocrLineCount = document.lines.count
        guard document.hasUsableText else {
            return keepOriginal(.skipped, "no readable text found; text-free screenshots are not named by this prototype")
        }

        let result: NamingResult
        do {
            result = try await provider.proposeTitle(for: document)
        } catch {
            return keepOriginal(.error, error.localizedDescription, usage: (error as? any TokenUsageReporting)?.usage)
        }

        switch result.outcome {
        case .insufficientInformation(let reason):
            return keepOriginal(.skipped, reason, usage: result.usage)
        case .title(let rawTitle):
            let requireGrounding = provider.info.kind == .languageModel
            switch TitlePolicy.validate(rawTitle, against: document, requireGrounding: requireGrounding) {
            case .failure(let rejection):
                return keepOriginal(.skipped, rejection.reason, usage: result.usage)
            case .success(let title):
                guard let filename = formatter.filename(title: title, date: timestamp.date, pathExtension: file.pathExtension) else {
                    return keepOriginal(.skipped, TitleRejection.empty.reason, usage: result.usage)
                }
                proposal.status = .proposed
                proposal.proposedFilename = filename
                proposal.title = title
                proposal.usage = result.usage
                return proposal
            }
        }
    }
}
