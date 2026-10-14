import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SmartScreenshotCore

/// Runs the same entry point as the executable, with real Vision OCR on synthetic images.
@Suite("End to end")
struct EndToEndTests {
    func run(_ arguments: [String], environment: [String: String] = [:], dependencies: SmartScreenshotCLI.Dependencies) async
        -> (status: Int32, stdout: String, stderr: String)
    {
        let capture = OutputCapture()
        let status = await SmartScreenshotCLI.run(
            arguments: arguments,
            environment: environment,
            output: capture.output,
            dependencies: dependencies
        )
        return (status, capture.stdout, capture.stderr)
    }

    func expectedName(_ title: String, for file: URL) throws -> String {
        let created = try FileTimestamp.read(from: file).date
        return "\(title) — \(FilenameFormatter(timeZone: utc).timestamp(for: created)).\(file.pathExtension)"
    }

    @Test("Local mode proposes names from real OCR and leaves every input byte and name unchanged")
    func localRunLeavesInputsUnchanged() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try SyntheticImage.write(to: folder.file("Screenshot 2026-10-07 at 14.32.05.png"), blocks: SyntheticImage.headingPage("Quarterly Revenue Dashboard"))
        try SyntheticImage.write(to: folder.file("Blank.png"), blocks: [])
        try SyntheticImage.write(to: folder.file("Settings.JPG"), type: .jpeg, blocks: SyntheticImage.headingPage("Bluetooth Devices"))
        let canWriteHEIC = SyntheticImage.canWrite(.heic)
        if canWriteHEIC {
            try SyntheticImage.write(to: folder.file("Article.heic"), type: .heic, blocks: SyntheticImage.headingPage("Release Checklist"))
        }
        try folder.write("not an image", to: "Corrupt.png")
        try folder.write("ignored", to: "notes.txt")
        try SyntheticImage.write(to: folder.file(".hidden.png"), blocks: SyntheticImage.headingPage("Hidden Heading"))
        try FileManager.default.createDirectory(at: folder.file("nested"), withIntermediateDirectories: true)
        try SyntheticImage.write(to: folder.file("nested/Inner.png"), blocks: SyntheticImage.headingPage("Nested Heading"))
        let before = try folder.snapshot()

        let result = await run(
            ["propose", folder.url.path, "--provider", "local", "--format", "json"],
            dependencies: .init(timeZone: utc)
        )

        #expect(try folder.snapshot() == before)
        #expect(result.status == SmartScreenshotCLI.ExitCode.fileErrors)  // Corrupt.png fails; the batch continues.
        let report = try jsonObject(result.stdout)
        #expect(report["files_modified"] as? Bool == false)
        let provider = try #require(report["provider"] as? [String: Any])
        #expect(provider["kind"] as? String == "heuristic")
        #expect(provider["sends_text_off_device"] as? Bool == false)

        let results = try #require(report["results"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0["original_filename"] as? String ?? "", $0) })
        let expectedOrder = (canWriteHEIC ? ["Article.heic"] : [])
            + ["Blank.png", "Corrupt.png", "Screenshot 2026-10-07 at 14.32.05.png", "Settings.JPG"]
        #expect(results.map { $0["original_filename"] as? String } == expectedOrder)
        #expect(results.allSatisfy { $0["provider"] as? String == "local" })

        let dashboard = try #require(byName["Screenshot 2026-10-07 at 14.32.05.png"])
        #expect(dashboard["status"] as? String == "proposed")
        #expect(dashboard["proposed_filename"] as? String
            == (try expectedName("Quarterly Revenue Dashboard", for: folder.file("Screenshot 2026-10-07 at 14.32.05.png"))))
        #expect(dashboard["timestamp_source"] as? String == "file-creation-time")

        let settings = try #require(byName["Settings.JPG"])
        #expect(settings["proposed_filename"] as? String == (try expectedName("Bluetooth Devices", for: folder.file("Settings.JPG"))))
        if canWriteHEIC {
            #expect(byName["Article.heic"]?["proposed_filename"] as? String
                == (try expectedName("Release Checklist", for: folder.file("Article.heic"))))
        }

        let blank = try #require(byName["Blank.png"])
        #expect(blank["status"] as? String == "skipped")
        #expect(blank["proposed_filename"] as? String == "Blank.png")
        // Every result carries the same keys; absent values are null.
        #expect(Set(blank.keys) == Set(dashboard.keys))
        #expect(blank["title"] is NSNull)
        #expect(dashboard["usage"] is NSNull)

        let corrupt = try #require(byName["Corrupt.png"])
        #expect(corrupt["status"] as? String == "error")
        #expect(corrupt["proposed_filename"] as? String == "Corrupt.png")

        let summary = try #require(report["summary"] as? [String: Any])
        #expect(summary["total"] as? Int == expectedOrder.count)
        #expect(summary["errors"] as? Int == 1)
        #expect(summary["skipped"] as? Int == 1)
    }

    @Test("Text output shows original name, proposed name, provider, and status")
    func textOutput() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.file("Screenshot 1.png")
        try SyntheticImage.write(to: file, blocks: SyntheticImage.headingPage("Quarterly Revenue Dashboard"))

        let result = await run(["propose", file.path], dependencies: .init(timeZone: utc))
        #expect(result.status == SmartScreenshotCLI.ExitCode.success)
        #expect(result.stdout.contains("no files are renamed or modified"))
        #expect(result.stdout.contains("not an AI summary"))
        #expect(result.stdout.contains("[1/1] Screenshot 1.png"))
        #expect(result.stdout.contains("status:   proposed"))
        #expect(result.stdout.contains("proposed: \(try expectedName("Quarterly Revenue Dashboard", for: file))"))
        #expect(result.stdout.contains("provider: local (heuristic)"))
        #expect(result.stderr.isEmpty)
    }

    @Test("Gemini mode reports usage, keeps going after a network failure, and never prints the key")
    func geminiBatchWithMockedNetwork() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for name in ["a.png", "b.png", "c.png"] {
            try folder.write("stubbed", to: name)
        }
        let checklist = ocrDocument([ocrLine("Release Checklist", top: 0.1, height: 0.08)]
            + (0..<4).map { ocrLine("Item \($0) needs sign-off", top: 0.3 + Double($0) * 0.05) })
        let recognizer = StubRecognizer(documents: ["a.png": pandasErrorDocument, "b.png": checklist, "c.png": checklist])
        let transport = MockTransport([
            .status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module"))),
            .failure(.notConnectedToInternet),
            .status(200, body: geminiBody(answer: insufficientAnswer, promptTokens: 50, outputTokens: 7)),
        ])
        let key = "test-key-not-real-1111"

        let result = await run(
            ["propose", folder.url.path, "--provider", "gemini", "--format", "json"],
            environment: ["GEMINI_API_KEY": key],
            dependencies: .init(recognizer: recognizer, geminiTransport: transport, sleep: { _ in }, timeZone: utc)
        )

        #expect(result.status == SmartScreenshotCLI.ExitCode.fileErrors)
        #expect(!result.stdout.contains(key))
        #expect(!result.stderr.contains(key))
        #expect(await transport.requests.count == 3)

        let report = try jsonObject(result.stdout)
        let provider = try #require(report["provider"] as? [String: Any])
        #expect(provider["model"] as? String == "gemini-2.5-flash-lite")
        #expect(provider["sends_text_off_device"] as? Bool == true)
        let results = try #require(report["results"] as? [[String: Any]])
        #expect(results.map { $0["status"] as? String } == ["proposed", "error", "skipped"])
        #expect(results[0]["proposed_filename"] as? String == (try expectedName("Python missing pandas module", for: folder.file("a.png"))))
        #expect((results[0]["usage"] as? [String: Any])?["total_tokens"] as? Int == 129)
        #expect((results[1]["reason"] as? String)?.contains("network error") == true)
        #expect(results[1]["proposed_filename"] as? String == "b.png")
        #expect(results[1]["usage"] is NSNull)
        #expect(results[1]["title"] is NSNull)
        #expect(results[2]["proposed_filename"] as? String == "c.png")

        let usage = try #require((report["summary"] as? [String: Any])?["usage"] as? [String: Any])
        #expect(usage["prompt_tokens"] as? Int == 170)
        #expect(usage["output_tokens"] as? Int == 16)
        #expect(usage["total_tokens"] as? Int == 186)
    }

    @Test("Gemini text output names the model and reports tokens per file and in total")
    func geminiTextOutput() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write("stubbed", to: "a.png")
        let transport = MockTransport([.status(200, body: geminiBody(answer: titleAnswer("Python missing pandas module")))])

        let result = await run(
            ["propose", file.path, "--provider", "gemini"],
            environment: ["GEMINI_API_KEY": "test-key-not-real-2222"],
            dependencies: .init(recognizer: StubRecognizer(documents: ["a.png": pandasErrorDocument]), geminiTransport: transport, timeZone: utc)
        )
        #expect(result.status == SmartScreenshotCLI.ExitCode.success)
        #expect(result.stdout.contains("extracted text and layout (never image pixels) are sent to the Gemini API"))
        #expect(result.stdout.contains("proposed: \(try expectedName("Python missing pandas module", for: file))"))
        #expect(result.stdout.contains("provider: gemini (gemini-2.5-flash-lite) · tokens: 120 prompt, 9 output, 129 total"))
        #expect(result.stdout.contains("Gemini tokens: 120 prompt, 9 output, 129 total."))
    }

    @Test("Gemini without GEMINI_API_KEY fails fast with a configuration error")
    func geminiWithoutKey() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("stubbed", to: "a.png")
        let transport = MockTransport([])

        let json = await run(
            ["propose", folder.url.path, "--provider", "gemini", "--format", "json"],
            dependencies: .init(recognizer: StubRecognizer(documents: [:]), geminiTransport: transport)
        )
        #expect(json.status == SmartScreenshotCLI.ExitCode.usage)
        let failure = try #require(try jsonObject(json.stdout)["error"] as? [String: Any])
        #expect(failure["kind"] as? String == "configuration")
        #expect((failure["message"] as? String)?.contains("GEMINI_API_KEY is not set") == true)
        #expect(json.stderr.contains("GEMINI_API_KEY is not set"))

        let text = await run(["propose", folder.url.path, "--provider", "gemini"], dependencies: .init(geminiTransport: transport))
        #expect(text.status == SmartScreenshotCLI.ExitCode.usage)
        #expect(text.stdout.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test("Usage errors print help and exit with status 2")
    func usageError() async {
        let result = await run(["propose", "/samples", "--provider", "openai"], dependencies: .init())
        #expect(result.status == SmartScreenshotCLI.ExitCode.usage)
        #expect(result.stderr.contains("unknown provider `openai`"))
        #expect(result.stderr.contains("USAGE: smart-screenshot propose"))
    }
}
