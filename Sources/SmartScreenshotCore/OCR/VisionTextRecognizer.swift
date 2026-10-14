import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts text from an image file.
public protocol TextRecognizing: Sendable {
    func recognizeText(in fileURL: URL) throws -> RecognizedDocument
}

public enum TextRecognitionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case undecodableImage
    case recognitionFailed(String)

    public var description: String {
        switch self {
        case .undecodableImage:
            "could not decode the image (corrupt file or a format this Mac cannot read)"
        case .recognitionFailed(let message):
            "text recognition failed: \(message)"
        }
    }
}

/// On-device OCR using Apple Vision's `VNRecognizeTextRequest`. Reads the file only; makes no network requests.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in fileURL: URL) throws -> RecognizedDocument {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options),
              CGImageSourceGetCount(source) > 0
        else {
            throw TextRecognitionError.undecodableImage
        }
        // HEIC containers can hold several images; use the primary one.
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else {
            throw TextRecognitionError.undecodableImage
        }
        let orientation = Self.orientation(of: source, at: index)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Screenshots can contain any script; let Vision pick the recognition model per image.
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TextRecognitionError.recognitionFailed(error.localizedDescription)
        }

        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision boxes are normalized with a bottom-left origin; flip to top-left.
            let box = observation.boundingBox
            return RecognizedLine(
                text: text,
                confidence: Double(candidate.confidence),
                boundingBox: NormalizedRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            )
        }

        // Vision reports boxes relative to the upright image, so report upright dimensions too.
        let isRotated = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        return RecognizedDocument(
            imageWidth: isRotated ? image.height : image.width,
            imageHeight: isRotated ? image.width : image.height,
            lines: lines
        )
    }

    private static func orientation(of source: CGImageSource, at index: Int) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue)
        else {
            return .up
        }
        return orientation
    }
}
