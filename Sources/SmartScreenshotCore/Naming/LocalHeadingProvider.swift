import Foundation

/// Uses a visually prominent OCR line, such as a page heading, verbatim as the title.
///
/// This is a conservative heuristic, not an AI summary. It never paraphrases, and it reports
/// insufficient information when no line stands out from the surrounding text.
public struct LocalHeadingProvider: NamingProvider {
    public let info = ProviderInfo(
        id: "local",
        kind: .heuristic,
        model: nil,
        sendsTextOffDevice: false,
        summary: "on-device OCR heading heuristic (not an AI summary); makes no network requests"
    )

    public init() {}

    public func proposeTitle(for document: RecognizedDocument) async throws -> NamingResult {
        guard let heading = HeadingSelector.heading(in: document) else {
            return NamingResult(outcome: .insufficientInformation(reason: "no prominent heading found in the OCR text"))
        }
        return NamingResult(outcome: .title(heading))
    }
}

enum HeadingSelector {
    /// A heading must be at least this much taller than the median line. Vision's box heights vary by up to
    /// about 1.4x between body lines of the same font size, so the margin is deliberately wide.
    static let prominenceRatio = 1.5
    static let minimumConfidence = 0.5
    static let maxWords = 12
    /// Lines a wrapped heading may span.
    static let maxHeadingLines = 3

    static func heading(in document: RecognizedDocument) -> String? {
        let lines = document.lines
        let median = document.medianLineHeight
        guard median > 0 else { return nil }
        // With fewer than three lines there is no meaningful body-text size to compare against,
        // so require multi-word text instead of prominence.
        let hasBodyText = lines.count >= 3

        var best: (index: Int, score: Double)?
        for (index, line) in lines.enumerated() where isCandidate(line) {
            let relativeSize = line.boundingBox.height / median
            let isMultiWord = words(line.text).count >= 2
            let qualifies = hasBodyText ? relativeSize >= prominenceRatio : isMultiWord
            guard qualifies else { continue }
            // Larger text wins; among similar sizes, prefer multi-word lines nearer the top.
            let score = relativeSize + (isMultiWord ? 0.15 : 0) - 0.25 * line.boundingBox.y
            if score > best?.score ?? -.infinity {
                best = (index, score)
            }
        }
        guard let best else { return nil }
        return headingBlock(around: best.index, in: lines)
    }

    static func isCandidate(_ line: RecognizedLine) -> Bool {
        let text = line.text
        let wordCount = words(text).count
        guard line.confidence >= minimumConfidence, (1...maxWords).contains(wordCount) else { return false }

        let visible = text.filter { !$0.isWhitespace }
        let letters = visible.filter(\.isLetter).count
        // Mostly letters: excludes clocks, prices, percentages, and numeric labels.
        guard letters >= 3, Double(letters) >= 0.6 * Double(visible.count) else { return false }
        // A long line ending in a period reads as body text, not a heading.
        if wordCount > 8, text.hasSuffix(".") { return false }
        // Single tokens with dots, slashes, colons, or @ are URLs, paths, domains, or handles.
        if wordCount == 1, text.contains(where: { ".:/\\@".contains($0) }) { return false }
        if text.contains("://") || text.localizedCaseInsensitiveContains("www.") { return false }
        return !SensitiveText.containsSensitiveContent(text) && !TitlePolicy.isGeneric(text)
    }

    /// Joins the chosen line with adjacent lines that continue the same wrapped heading, in either direction.
    static func headingBlock(around index: Int, in lines: [RecognizedLine]) -> String {
        var start = index
        var end = index
        while start > 0, end - start + 1 < maxHeadingLines, continues(lines[start - 1], with: lines[start]) {
            start -= 1
        }
        while end + 1 < lines.count, end - start + 1 < maxHeadingLines, continues(lines[end], with: lines[end + 1]) {
            end += 1
        }
        return lines[start...end].map(\.text).joined(separator: " ")
    }

    /// Whether `next` continues a heading wrapped from `line`: similar size, aligned, and directly below.
    static func continues(_ line: RecognizedLine, with next: RecognizedLine) -> Bool {
        let above = line.boundingBox
        let below = next.boundingBox
        let similarSize = abs(below.height - above.height) <= 0.15 * max(above.height, below.height)
        let aligned = abs(below.x - above.x) <= 0.02 || abs(below.midX - above.midX) <= 0.02
        let gap = below.y - above.maxY
        let directlyBelow = gap >= -0.2 * above.height && gap <= 0.8 * above.height
        return similarSize && aligned && directlyBelow && isCandidate(line) && isCandidate(next)
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
