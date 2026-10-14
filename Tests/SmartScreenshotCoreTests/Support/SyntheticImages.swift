import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Text drawn into a synthetic screenshot. `y` is the distance from the top edge to the top of the text.
struct TextBlock {
    var text: String
    var size: CGFloat
    var x: CGFloat = 60
    var y: CGFloat
    var font = "Helvetica"
}

/// Draws synthetic screenshots at test time, so no real (possibly personal) screenshots are committed.
enum SyntheticImage {
    static func write(to url: URL, width: Int = 1200, height: Int = 600, type: UTType = .png, blocks: [TextBlock]) throws {
        let image = try render(width: width, height: height, blocks: blocks)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func canWrite(_ type: UTType) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(type.identifier)
    }

    /// A page with a large bold heading above several lines of body text.
    static func headingPage(_ heading: String, bodyLines: Int = 5) -> [TextBlock] {
        [TextBlock(text: heading, size: 44, y: 60, font: "Helvetica-Bold")]
            + (0..<bodyLines).map { index in
                TextBlock(text: "Body text line number \(index + 1) describes the details below", size: 16, y: 200 + CGFloat(index) * 30)
            }
    }

    private static func render(width: Int, height: Int, blocks: [TextBlock]) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for block in blocks {
            let font = CTFontCreateWithName(block.font as CFString, block.size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: block.text, attributes: attributes))
            // Core Graphics uses a bottom-left origin.
            context.textPosition = CGPoint(x: block.x, y: CGFloat(height) - block.y - CTFontGetAscent(font))
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
