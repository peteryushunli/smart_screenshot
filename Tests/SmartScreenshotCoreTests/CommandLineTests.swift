import Foundation
import Testing
@testable import SmartScreenshotCore

@Suite("Input collection")
struct InputCollectorTests {
    @Test("A folder yields only its immediate, visible, supported images in Finder-like order")
    func folder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for name in ["Shot 10.png", "Shot 2.png", "shot 1.PNG", "b.jpeg", "c.heif", "d.HEIC", "e.jpg",
                     "animation.gif", "notes.txt", ".hidden.png", "nested/inner.png"] {
            try folder.write("x", to: name)
        }
        let selection = try InputCollector.collect(path: folder.url.path)
        #expect(selection.isDirectory)
        #expect(selection.files.map(\.lastPathComponent) == ["b.jpeg", "c.heif", "d.HEIC", "e.jpg", "shot 1.PNG", "Shot 2.png", "Shot 10.png"])
        #expect(selection.ignoredEntryCount == 3)  // animation.gif, notes.txt, nested/
    }

    @Test("A single file is returned even when unsupported, so it can be reported")
    func singleFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let text = try folder.write("x", to: "notes.txt")
        let selection = try InputCollector.collect(path: text.path)
        #expect(!selection.isDirectory)
        #expect(selection.files.map(\.lastPathComponent) == ["notes.txt"])
    }

    @Test("A missing path is an input error")
    func missingPath() {
        #expect(throws: InputError.notFound("/definitely/not/here")) {
            try InputCollector.collect(path: "/definitely/not/here")
        }
    }
}

@Suite("Command-line parsing")
struct CommandLineParserTests {
    @Test("Parses the documented commands", arguments: [
        (["propose", "/samples", "--provider", "local"], ProposeOptions(path: "/samples")),
        (["propose", "/samples", "--provider", "gemini"], ProposeOptions(path: "/samples", provider: .gemini)),
        (["propose", "/samples", "--provider", "gemini", "--format", "json"],
         ProposeOptions(path: "/samples", provider: .gemini, format: .json)),
        (["propose", "--provider=gemini", "--model=gemini-3.5-flash-lite", "/samples"],
         ProposeOptions(path: "/samples", provider: .gemini, model: "gemini-3.5-flash-lite")),
        (["propose", "/samples"], ProposeOptions(path: "/samples")),
        (["propose", "--format", "json", "--", "-odd name.png"], ProposeOptions(path: "-odd name.png", format: .json)),
    ])
    func valid(arguments: [String], expected: ProposeOptions) throws {
        #expect(try CommandLineParser.parse(arguments) == .propose(expected))
    }

    @Test("Rejects invalid usage", arguments: [
        [],
        ["rename", "/samples"],
        ["propose"],
        ["propose", "/samples", "--provider", "openai"],
        ["propose", "/samples", "--format", "xml"],
        ["propose", "/samples", "--model", "gemini-2.5-flash"],
        ["propose", "/samples", "/more"],
        ["propose", "/samples", "--dry-run"],
        ["propose", "/samples", "--provider"],
        ["propose", ""],
        ["propose", "--provider=", "/samples"],
    ])
    func invalid(arguments: [String]) {
        #expect(throws: UsageError.self) {
            try CommandLineParser.parse(arguments)
        }
    }

    @Test("Help and version")
    func helpAndVersion() throws {
        #expect(try CommandLineParser.parse(["--help"]) == .help)
        #expect(try CommandLineParser.parse(["propose", "-h"]) == .help)
        #expect(try CommandLineParser.parse(["--version"]) == .version)
        #expect(CommandLineParser.usage.contains("Never renames, moves, or modifies"))
    }
}
