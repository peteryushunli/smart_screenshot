import Foundation

/// Converts proposed titles into safe, readable, single filename components.
public enum TitleSanitizer {
    /// Maximum length of the descriptive part of a filename, in user-perceived characters.
    public static let maxLength = 80

    /// Path separators, the Finder's legacy separator (`:`), and characters other platforms reject.
    static let unsafeScalars: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{FFFD}"]
    /// Zero-width joiners are invisible formatting characters but are needed for some scripts and emoji.
    static let allowedFormatScalars: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
    /// Trimmed from both ends so names never start with a dot (hidden) or hyphen (option-like).
    static let edgeCharacters: Set<Character> = [" ", ".", "-", "_", "~", ",", ";", "—", "–", "·", "•"]

    /// Returns a sanitized title, or an empty string when nothing usable remains.
    public static func sanitize(_ raw: String) -> String {
        var text = raw.precomposedStringWithCanonicalMapping
        text = SensitiveText.remove(from: text)
        text = replaceUnsafeScalars(in: text)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = stripGenericFraming(text)
        text = trimEdges(text)
        text = truncate(text, toLength: maxLength)
        return trimEdges(text)
    }

    /// Replaces control characters, line breaks, and unsafe punctuation with spaces, and drops invisible
    /// formatting characters such as bidirectional overrides that can disguise a filename.
    static func replaceUnsafeScalars(in text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                scalars.append(" ")
            case .format where !allowedFormatScalars.contains(scalar), .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(unsafeScalars.contains(scalar) ? " " : scalar)
            }
        }
        return String(scalars)
    }

    /// Removes framing that adds no information, such as "Screenshot of …".
    static func stripGenericFraming(_ text: String) -> String {
        text
            .replacing(
                #/(?i)^(?:an?\s+|the\s+)?(?:screenshot|screen\s?shot|screen\s?capture|screen\s?grab|image|picture|photo)\s+(?:of|showing|shows|displaying|depicting|with)\s+(?:an?\s+|the\s+)?/#,
                with: ""
            )
            .replacing(#/(?i)\s+(?:screenshot|screen\s?shot)$/#, with: "")
    }

    static func trimEdges(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !edgeCharacters.contains($0) }),
              let last = text.lastIndex(where: { !edgeCharacters.contains($0) })
        else {
            return ""
        }
        return String(text[start...last])
    }

    /// Truncates to `limit` characters, preferring a word boundary in the second half of the allowed length.
    static func truncate(_ text: String, toLength limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) >= limit / 2 {
            return String(prefix[..<space])
        }
        return String(prefix)
    }
}

public enum TitleRejection: Error, Equatable, Sendable {
    case empty
    case generic
    case ungrounded

    public var reason: String {
        switch self {
        case .empty: "no usable title remained after removing unsafe or sensitive content"
        case .generic: "the proposed title was too generic to be useful"
        case .ungrounded: "the proposed title did not match any OCR text, so it may be invented"
        }
    }
}

/// Decides whether a sanitized title is specific enough, and supported by the OCR text, to use in a filename.
public enum TitlePolicy {
    /// Words that describe the medium rather than the content. A title made only of these is rejected.
    static let genericWords: Set<String> = [
        "screenshot", "screenshots", "screen", "screens", "shot", "capture", "grab", "image", "picture", "photo",
        "snapshot", "page", "webpage", "web", "site", "website", "window", "app", "application", "program",
        "software", "text", "document", "file", "content", "untitled", "view", "display", "desktop", "browser",
        "tab", "interface", "ui", "home", "menu", "settings", "preferences", "loading", "welcome", "error",
        "message", "dialog", "popup", "notification", "info", "information", "details", "new", "blank", "empty",
        "unknown", "misc", "various", "item", "items", "list", "data",
    ]
    static let fillerWords: Set<String> = [
        "a", "an", "the", "of", "on", "in", "at", "to", "for", "with", "and", "or", "from", "by", "about",
        "show", "shows", "showing", "displaying", "this", "that", "my", "your", "some", "is", "are", "it", "its",
    ]

    /// Sanitizes `raw`, then checks that it is specific and, when `requireGrounding` is set, that at least
    /// one distinctive word also appears in the OCR text. Grounding is a lexical check, not a model score.
    public static func validate(
        _ raw: String,
        against document: RecognizedDocument,
        requireGrounding: Bool
    ) -> Result<String, TitleRejection> {
        let title = TitleSanitizer.sanitize(raw)
        guard title.contains(where: { $0.isLetter || $0.isNumber }) else { return .failure(.empty) }
        guard !isGeneric(title) else { return .failure(.generic) }
        if requireGrounding, !isGrounded(title, in: document) { return .failure(.ungrounded) }
        return .success(title)
    }

    public static func isGeneric(_ title: String) -> Bool {
        words(in: title).allSatisfy { genericWords.contains($0) || fillerWords.contains($0) }
    }

    static func isGrounded(_ title: String, in document: RecognizedDocument) -> Bool {
        let ocrText = normalize(document.lines.map(\.text).joined(separator: " "))
        let distinctiveWords = words(in: title).filter { !genericWords.contains($0) && !fillerWords.contains($0) }
        return distinctiveWords.contains { word in
            if word.unicodeScalars.contains(where: isCJK) {
                // CJK text has no spaces between words: look for any two-character run.
                let characters = Array(word)
                guard characters.count >= 2 else { return ocrText.contains(word) }
                return (0..<characters.count - 1).contains { ocrText.contains(String(characters[$0...$0 + 1])) }
            }
            guard word.count >= 3 else { return false }
            // A short stem tolerates inflection, e.g. "failure" matches "failed".
            return ocrText.contains(word.count >= 5 ? String(word.prefix(4)) : word)
        }
    }

    static func words(in text: String) -> [String] {
        normalize(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }
}
