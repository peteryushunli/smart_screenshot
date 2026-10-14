import Foundation
import Testing
@testable import SmartScreenshotCore

@Suite("Title sanitizing")
struct TitleSanitizerTests {
    @Test("Unsafe characters become spaces and edges are trimmed", arguments: [
        ("Python: missing / pandas module", "Python missing pandas module"),
        ("../../etc/passwd", "etc passwd"),
        (#"C:\Users\report*final?.txt"#, "C Users report final .txt"),
        ("<script>alert|1</script>", "script alert 1 script"),
        ("Line one\nLine two\tthree\u{0007}", "Line one Line two three"),
        (".hidden title", "hidden title"),
        ("--rm -rf notes", "rm -rf notes"),
        ("Release notes — ", "Release notes"),
        ("Plan\u{00A0}\u{202F}B", "Plan B"),
    ])
    func unsafeCharacters(input: String, expected: String) {
        #expect(TitleSanitizer.sanitize(input) == expected)
    }

    @Test("Invisible and bidirectional control characters are removed")
    func invisibleCharacters() {
        // U+202E RIGHT-TO-LEFT OVERRIDE can make "gnp.exe" display as "exe.png".
        #expect(TitleSanitizer.sanitize("Invoice \u{202E}gnp.exe") == "Invoice gnp.exe")
        #expect(TitleSanitizer.sanitize("Zero\u{200B}width\u{FEFF} text") == "Zerowidth text")
    }

    @Test("Readable Unicode is preserved and normalized")
    func unicode() {
        // Swift compares strings by canonical equivalence, so compare scalars to check NFC composition.
        #expect(Array(TitleSanitizer.sanitize("Cafe\u{0301} menu").unicodeScalars) == Array("Caf\u{00E9} menu".unicodeScalars))
        #expect(TitleSanitizer.sanitize("東京の天気予報") == "東京の天気予報")
        #expect(TitleSanitizer.sanitize("Développeur 👩‍💻 notes") == "Développeur 👩‍💻 notes")
    }

    @Test("Empty or punctuation-only titles sanitize to nothing", arguments: ["", "   ", "///:::***", "....", "— – -", "\n\t"])
    func emptyTitles(input: String) {
        #expect(TitleSanitizer.sanitize(input).isEmpty)
    }

    @Test("Generic framing is stripped")
    func genericFraming() {
        #expect(TitleSanitizer.sanitize("Screenshot of a Stripe pricing page") == "Stripe pricing page")
        #expect(TitleSanitizer.sanitize("Image showing the Xcode build log") == "Xcode build log")
        #expect(TitleSanitizer.sanitize("Python error screenshot") == "Python error")
        #expect(TitleSanitizer.sanitize("Image compression settings") == "Image compression settings")
    }

    @Test("The descriptive part is capped at 80 characters, at a word boundary when possible")
    func lengthCap() {
        let words = Array(repeating: "Kubernetes deployment rollout", count: 10).joined(separator: " ")
        let capped = TitleSanitizer.sanitize(words)
        #expect(capped.count <= TitleSanitizer.maxLength)
        #expect(words.hasPrefix(capped))
        #expect(!capped.hasSuffix(" "))
        #expect(words[words.index(words.startIndex, offsetBy: capped.count)] == " ")

        let unbroken = String(repeating: "a", count: 200)
        #expect(TitleSanitizer.sanitize(unbroken) == String(repeating: "a", count: 80))

        let wide = String(repeating: "界", count: 120)
        #expect(TitleSanitizer.sanitize(wide).count == 80)
    }

    @Test("Credentials and personal identifiers are removed from titles", arguments: [
        ("Login for jane.doe@example.com", "Login for"),
        ("Card 4111 1111 1111 1111 declined", "Card declined"),
        ("Account 123456789 overview", "Account overview"),
        ("Call (555) 123-4567 today", "Call today"),
        ("API key fake-0a1b2c3d4e5f6a7b8c9d0e1f", "API key"),
        ("Password: hunter2 reset", "Password reset"),
        ("Docs at https://example.com/reset?token=abc123", "Docs at"),
        ("Release notes 2026-10-07", "Release notes 2026-10-07"),
    ])
    func sensitiveContent(input: String, expected: String) {
        #expect(TitleSanitizer.sanitize(input) == expected)
    }
}

@Suite("Sensitive text redaction")
struct SensitiveTextTests {
    @Test("OCR text sent off-device gets placeholders instead of values")
    func redaction() {
        let redacted = SensitiveText.redact(
            "Email jane.doe@example.com card 4111-1111-1111-1111 password: hunter2 key tok9f8e7d6c5b4a3f2e1d0c9b8a"
        )
        #expect(redacted == "Email [email] card [number] password: [secret] key [secret]")
        #expect(SensitiveText.redact("https://example.com/path?session=abc123#frag") == "https://example.com/path")
    }

    @Test("Ordinary text is left alone", arguments: [
        "ModuleNotFoundError: No module named 'pandas'",
        "Revenue grew 12% to $1,234,567 in Q3 2026",
        "Meeting at 14:30 on 2026-10-07",
        "swift-package-manager release notes",
    ])
    func ordinaryText(text: String) {
        #expect(!SensitiveText.containsSensitiveContent(text))
    }
}

@Suite("Title policy")
struct TitlePolicyTests {
    @Test("Generic titles are rejected", arguments: [
        "Screenshot of webpage", "App window", "Untitled document", "Screen capture", "Settings", "Error message",
    ])
    func genericTitles(title: String) {
        #expect(TitlePolicy.validate(title, against: pandasErrorDocument, requireGrounding: false) == .failure(.generic))
    }

    @Test("Titles with nothing usable left are rejected as empty", arguments: ["", "   ", "???", "jane.doe@example.com"])
    func emptyTitles(title: String) {
        #expect(TitlePolicy.validate(title, against: pandasErrorDocument, requireGrounding: false) == .failure(.empty))
    }

    @Test("Model titles must share a distinctive word with the OCR text")
    func grounding() {
        #expect(
            TitlePolicy.validate("Python missing pandas module", against: pandasErrorDocument, requireGrounding: true)
                == .success("Python missing pandas module")
        )
        #expect(
            TitlePolicy.validate("Quarterly budget review", against: pandasErrorDocument, requireGrounding: true)
                == .failure(.ungrounded)
        )
        // Inflection and accents still match.
        let cafe = ocrDocument([ocrLine("Café opening hours", top: 0.1), ocrLine("Deploy failed at 09:00", top: 0.2)])
        #expect(TitlePolicy.validate("Cafe deployment failure", against: cafe, requireGrounding: true) == .success("Cafe deployment failure"))
        // CJK text has no spaces; two-character runs are matched.
        let japanese = ocrDocument([ocrLine("一般 設定 情報", top: 0.1)])
        #expect(TitlePolicy.validate("設定画面", against: japanese, requireGrounding: true) == .success("設定画面"))
    }
}

@Suite("Filename formatting")
struct FilenameFormatterTests {
    let date = Date(timeIntervalSince1970: 1_791_383_525)  // 2026-10-07 14:32:05 UTC

    @Test("Matches the documented example")
    func documentedExample() {
        let formatter = FilenameFormatter(timeZone: utc)
        #expect(
            formatter.filename(title: "Python missing pandas module", date: date, pathExtension: "png")
                == "Python missing pandas module — 2026-10-07 143205.png"
        )
    }

    @Test("Preserves the original extension exactly", arguments: ["PNG", "jpeg", "JPG", "heic", "HEIF"])
    func extensions(pathExtension: String) throws {
        let name = try #require(FilenameFormatter(timeZone: utc).filename(title: "Build log", date: date, pathExtension: pathExtension))
        #expect(name == "Build log — 2026-10-07 143205.\(pathExtension)")
    }

    @Test("Uses the given time zone")
    func timeZone() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(FilenameFormatter(timeZone: tokyo).timestamp(for: date) == "2026-10-07 233205")
    }

    @Test("Stays within the 255-byte APFS filename limit")
    func byteLimit() throws {
        let title = String(repeating: "界", count: 80)  // 240 bytes of UTF-8
        let name = try #require(FilenameFormatter(timeZone: utc).filename(title: title, date: date, pathExtension: "png"))
        #expect(name.utf8.count <= FilenameFormatter.maxFilenameBytes)
        #expect(name.hasSuffix(" — 2026-10-07 143205.png"))
        #expect(name.hasPrefix("界界界"))

        let oneHugeCharacter = "a" + String(repeating: "\u{0301}", count: 300)
        #expect(FilenameFormatter(timeZone: utc).filename(title: oneHugeCharacter, date: date, pathExtension: "png") == nil)
    }

    @Test("Reads the file creation time as the timestamp")
    func creationTime() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write("x", to: "a.png")
        let timestamp = try FileTimestamp.read(from: file)
        #expect(timestamp.source == .creationTime)
        #expect(abs(timestamp.date.timeIntervalSinceNow) < 60)
    }
}
