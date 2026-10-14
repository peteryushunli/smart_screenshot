import Foundation
import Testing
@testable import SmartScreenshotCore

@Suite("Local heading heuristic")
struct LocalHeadingTests {
    let provider = LocalHeadingProvider()

    func title(for document: RecognizedDocument) async throws -> String? {
        if case .title(let title) = try await provider.proposeTitle(for: document).outcome { return title }
        return nil
    }

    var bodyLines: [RecognizedLine] {
        (0..<5).map { ocrLine("Body text line \($0) with ordinary details", top: 0.3 + Double($0) * 0.05, height: 0.03) }
    }

    @Test("Identifies itself as a heuristic that stays on-device")
    func info() {
        #expect(provider.info.kind == .heuristic)
        #expect(!provider.info.sendsTextOffDevice)
        #expect(provider.info.summary.contains("not an AI summary"))
    }

    @Test("Picks the prominent heading over body text and interface chrome")
    func prominentHeading() async throws {
        let document = ocrDocument([
            ocrLine("Safari File Edit View History", top: 0.005, height: 0.02),
            ocrLine("Wed Oct 7 2:32 PM", top: 0.005, left: 0.8, height: 0.02),
            ocrLine("Quarterly Revenue Dashboard", top: 0.12, height: 0.07),
        ] + bodyLines)
        #expect(try await title(for: document) == "Quarterly Revenue Dashboard")
    }

    @Test("Skips uniform text such as a terminal, rather than guessing")
    func uniformText() async throws {
        let result = try await provider.proposeTitle(for: pandasErrorDocument)
        #expect(result.outcome == .insufficientInformation(reason: "no prominent heading found in the OCR text"))
    }

    @Test("Joins a heading wrapped over two lines")
    func wrappedHeading() async throws {
        let document = ocrDocument([
            ocrLine("How to Configure", top: 0.09, height: 0.057),
            ocrLine("Swift Package Manager", top: 0.163, height: 0.060),
        ] + bodyLines)
        #expect(try await title(for: document) == "How to Configure Swift Package Manager")
    }

    @Test("Ignores prominent lines that are unreliable, sensitive, generic, numeric, or URLs")
    func rejectedCandidates() async throws {
        for heading in [
            ocrLine("Blurry Heading Text", top: 0.1, height: 0.08, confidence: 0.3),
            ocrLine("jane.doe@example.com", top: 0.1, height: 0.08),
            ocrLine("Settings", top: 0.1, height: 0.08),
            ocrLine("$1,234.56", top: 0.1, height: 0.08),
            ocrLine("github.com/apple/swift", top: 0.1, height: 0.08),
        ] {
            #expect(try await title(for: ocrDocument([heading] + bodyLines)) == nil, "\(heading.text)")
        }
    }

    @Test("Short documents need multi-word text instead of a size contrast")
    func shortDocuments() async throws {
        #expect(try await title(for: ocrDocument([ocrLine("Quarterly Results", top: 0.4, height: 0.1)])) == "Quarterly Results")
        #expect(try await title(for: ocrDocument([ocrLine("Kubernetes", top: 0.4, height: 0.1)])) == nil)
    }
}

@Suite("Proposal runner")
struct ProposalRunnerTests {
    let folder: TemporaryFolder
    let file: URL

    init() throws {
        folder = try TemporaryFolder()
        file = try folder.write("placeholder bytes; the recognizer is stubbed", to: "Screenshot 2026-10-07 at 14.32.05.png")
    }

    func runner(_ provider: any NamingProvider, document: RecognizedDocument = pandasErrorDocument) -> ProposalRunner {
        ProposalRunner(
            recognizer: StubRecognizer(documents: [file.lastPathComponent: document]),
            provider: provider,
            formatter: FilenameFormatter(timeZone: utc)
        )
    }

    @Test("A screenshot without text is skipped without calling the provider")
    func noText() async throws {
        defer { folder.remove() }
        let spy = SpyProvider(result: .success(NamingResult(outcome: .title("Anything"))))
        let blank = ocrDocument([ocrLine("Il", top: 0.5, confidence: 0.3)])
        let proposal = await runner(spy, document: blank).propose(for: file)
        #expect(proposal.status == .skipped)
        #expect(proposal.proposedFilename == file.lastPathComponent)
        #expect(proposal.reason?.contains("no readable text") == true)
        #expect(await spy.callCount == 0)
    }

    @Test("Model titles that are generic, unsafe-only, or unsupported by OCR text are skipped", arguments: [
        ("Screenshot of webpage", TitleRejection.generic),
        ("/// ???", TitleRejection.empty),
        ("Quarterly budget review", TitleRejection.ungrounded),
    ])
    func rejectedTitles(title: String, rejection: TitleRejection) async throws {
        defer { folder.remove() }
        let usage = TokenUsage(promptTokens: 100, outputTokens: 8, totalTokens: 108)
        let spy = SpyProvider(result: .success(NamingResult(outcome: .title(title), usage: usage)))
        let proposal = await runner(spy).propose(for: file)
        #expect(proposal.status == .skipped)
        #expect(proposal.reason == rejection.reason)
        #expect(proposal.proposedFilename == file.lastPathComponent)
        #expect(proposal.usage == usage)
    }

    @Test("A grounded model title becomes the proposed filename")
    func proposed() async throws {
        defer { folder.remove() }
        let spy = SpyProvider(result: .success(NamingResult(outcome: .title("Python: missing pandas module"))))
        let proposal = await runner(spy).propose(for: file)
        let created = try FileTimestamp.read(from: file).date
        #expect(proposal.status == .proposed)
        #expect(proposal.title == "Python missing pandas module")
        #expect(proposal.proposedFilename == "Python missing pandas module — \(FilenameFormatter(timeZone: utc).timestamp(for: created)).png")
        #expect(proposal.timestamp?.source == .creationTime)
    }

    @Test("Provider failures become an error result that keeps the original name and reports usage")
    func providerFailure() async throws {
        defer { folder.remove() }
        let usage = TokenUsage(promptTokens: 90, outputTokens: 512, totalTokens: 602)
        let spy = SpyProvider(result: .failure(.incomplete(finishReason: "MAX_TOKENS", usage: usage)))
        let proposal = await runner(spy).propose(for: file)
        #expect(proposal.status == .error)
        #expect(proposal.proposedFilename == file.lastPathComponent)
        #expect(proposal.reason == "the Gemini response hit the output token limit before finishing")
        #expect(proposal.usage == usage)
    }

    @Test("Unsupported or undecodable files are errors, not crashes")
    func badFiles() async throws {
        defer { folder.remove() }
        let spy = SpyProvider(result: .success(NamingResult(outcome: .title("Anything"))))
        let text = try folder.write("hello", to: "notes.txt")
        #expect(await runner(spy).propose(for: text).status == .error)

        let corrupt = try folder.write("not a PNG", to: "corrupt.png")
        let vision = ProposalRunner(recognizer: VisionTextRecognizer(), provider: spy, formatter: FilenameFormatter(timeZone: utc))
        let proposal = await vision.propose(for: corrupt)
        #expect(proposal.status == .error)
        #expect(proposal.reason == TextRecognitionError.undecodableImage.description)
        #expect(await spy.callCount == 0)
    }
}
