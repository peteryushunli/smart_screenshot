import Foundation

/// A rectangle in normalized image coordinates (0...1) with a top-left origin.
public struct NormalizedRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One line of OCR text with the layout signals used to tell headings from surrounding interface text.
public struct RecognizedLine: Sendable, Equatable {
    public var text: String
    /// Vision's confidence for the recognized string, 0...1. This is OCR confidence, not a language-model score.
    public var confidence: Double
    public var boundingBox: NormalizedRect

    public init(text: String, confidence: Double, boundingBox: NormalizedRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// The OCR result for one image. Lines are kept in reading order: top to bottom, then left to right.
public struct RecognizedDocument: Sendable, Equatable {
    /// Lines below this confidence are too unreliable to count as evidence.
    public static let minimumEvidenceConfidence = 0.4

    public var imageWidth: Int
    public var imageHeight: Int
    public private(set) var lines: [RecognizedLine]

    public init(imageWidth: Int, imageHeight: Int, lines: [RecognizedLine]) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.lines = Self.readingOrder(lines)
    }

    /// Median line height, used as the reference size for body text.
    public var medianLineHeight: Double {
        let heights = lines.map(\.boundingBox.height).sorted()
        guard !heights.isEmpty else { return 0 }
        let middle = heights.count / 2
        return heights.count.isMultiple(of: 2) ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
    }

    /// Whether OCR found enough legible text to be worth naming. Text-free screenshots fail this check.
    public var hasUsableText: Bool {
        let letters = lines
            .filter { $0.confidence >= Self.minimumEvidenceConfidence }
            .reduce(0) { $0 + $1.text.filter(\.isLetter).count }
        return letters >= 3
    }

    /// Sorts top to bottom, groups lines whose vertical centers fall within the current row,
    /// and orders each row left to right.
    static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let byTop = lines.sorted { ($0.boundingBox.y, $0.boundingBox.x) < ($1.boundingBox.y, $1.boundingBox.x) }
        var ordered: [RecognizedLine] = []
        var row: [RecognizedLine] = []
        var rowBottom = -Double.infinity

        func flushRow() {
            ordered += row.sorted { ($0.boundingBox.x, $0.boundingBox.y) < ($1.boundingBox.x, $1.boundingBox.y) }
            row.removeAll()
        }

        for line in byTop {
            if !row.isEmpty, line.boundingBox.midY > rowBottom {
                flushRow()
            }
            if row.isEmpty {
                rowBottom = line.boundingBox.maxY
            }
            row.append(line)
        }
        flushRow()
        return ordered
    }
}
