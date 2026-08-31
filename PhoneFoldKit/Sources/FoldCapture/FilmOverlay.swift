import Foundation
import CoreGraphics
import CoreText
import FoldCore

/// The caption burned into an exported film.
///
/// PLAN.md Phase 4: "Optional burned-in overlay: protein name, accession, length, final mean
/// pLDDT, PhoneFold mark."
///
/// **Drawn once, blended per frame.** The text does not change while the film plays, so
/// rendering it into a bitmap at export resolution and alpha-blending that over each frame
/// costs one text layout for the whole film rather than one per frame - which at 3,000 frames
/// is the difference between an export and a wait.
///
/// It is deliberately not a RealityKit entity. A text entity would be in the scene, which means
/// it would orbit with the protein, be lit by the stage's lights, and sit at the mercy of the
/// depth buffer. A caption belongs on the film, not in the world.
public struct FilmOverlay: Sendable {

    /// What the caption says. Every field is optional because not every trajectory has one:
    /// a generated backbone has no accession and no name worth printing.
    public struct Caption: Sendable {
        public var name: String?
        public var accession: String?
        public var residueCount: Int?
        /// The final frame's mean confidence, and what that confidence actually is.
        public var confidence: Float?
        public var confidenceSource: ConfidenceSource?
        /// The trajectory's own claim - generated, simulated, predicted - which travels with
        /// the film for the same reason it travels with an exported structure.
        public var provenance: String?
        public var mark = "PhoneFold"

        public init(name: String? = nil, accession: String? = nil, residueCount: Int? = nil,
                    confidence: Float? = nil, confidenceSource: ConfidenceSource? = nil,
                    provenance: String? = nil) {
            self.name = name
            self.accession = accession
            self.residueCount = residueCount
            self.confidence = confidence
            self.confidenceSource = confidenceSource
            self.provenance = provenance
        }

        /// The title line, and the detail line under it.
        public var lines: (title: String, detail: String) {
            let title = name ?? accession ?? mark
            var parts: [String] = []
            if let accession, accession != title { parts.append(accession) }
            if let residueCount { parts.append("\(residueCount) residues") }
            if let confidence, let confidenceSource {
                parts.append(String(format: "%@ %.0f", confidenceSource.displayName,
                                    Double(confidence)))
            }
            if let provenance { parts.append(provenance) }
            return (title, parts.joined(separator: "  ·  "))
        }
    }

    /// Premultiplied BGRA, the same order the pixel buffer wants, so blending is a loop and
    /// not a conversion.
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    /// Build the caption at a given frame size.
    ///
    /// Type scales with the frame, so a 4K export is not a 1080p caption at a quarter of the
    /// size, and a vertical film's caption is not off the edge.
    public init?(caption: Caption, size: OffscreenStage.Size) {
        let scale = Float(size.height) / 1080
        let margin = CGFloat(56 * scale)
        let titleSize = CGFloat(34 * scale)
        let detailSize = CGFloat(19 * scale)
        let markSize = CGFloat(17 * scale)

        guard let space = CGColorSpace(name: CGColorSpace.linearSRGB),
              let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))

        let lines = caption.lines
        // Bottom left for the protein, bottom right for the mark: the protein is centred in
        // frame, so the corners are the only places a caption never covers it.
        Self.draw(lines.title, in: context, at: CGPoint(x: margin, y: margin + detailSize * 1.9),
                  size: titleSize, weight: .semibold, alpha: 0.92)
        if !lines.detail.isEmpty {
            Self.draw(lines.detail, in: context, at: CGPoint(x: margin, y: margin),
                      size: detailSize, weight: .regular, alpha: 0.6)
        }
        Self.draw(caption.mark, in: context,
                  at: CGPoint(x: CGFloat(size.width) - margin, y: margin),
                  size: markSize, weight: .medium, alpha: 0.45, alignRight: true)

        guard let data = context.data else { return nil }
        let count = size.width * size.height * 4
        pixels = [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self), count: count))
        width = size.width
        height = size.height
    }

    enum Weight { case regular, medium, semibold

        var name: String {
            switch self {
            case .regular: "HelveticaNeue"
            case .medium: "HelveticaNeue-Medium"
            case .semibold: "HelveticaNeue-Bold"
            }
        }
    }

    /// One line of text, drawn with Core Text.
    ///
    /// Core Text rather than `NSAttributedString.draw`, which is AppKit and UIKit on the two
    /// platforms and neither in a package that has to build for both.
    static func draw(_ text: String, in context: CGContext, at point: CGPoint,
                     size: CGFloat, weight: Weight, alpha: CGFloat,
                     alignRight: Bool = false) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName(weight.name as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        var x = point.x
        if alignRight {
            x -= CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        // A soft shadow, so white text stays readable if the protein drifts under it.
        context.setShadow(offset: .zero, blur: size * 0.35,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// Blend the caption over a frame, in place.
    ///
    /// Source-over with premultiplied source, which is one multiply and one add per channel -
    /// and it skips a fully transparent pixel outright, which is almost all of them.
    public func blend(into base: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        pixels.withUnsafeBufferPointer { overlay in
            for row in 0..<height {
                let source = row * width * 4
                let destination = row * bytesPerRow
                for column in 0..<width {
                    let s = source + column * 4
                    let alpha = Int(overlay[s + 3])
                    if alpha == 0 { continue }
                    let inverse = 255 - alpha
                    let d = destination + column * 4
                    for channel in 0..<3 {
                        let value = Int(overlay[s + channel])
                            + Int(base[d + channel]) * inverse / 255
                        base[d + channel] = UInt8(Swift.min(value, 255))
                    }
                }
            }
        }
    }
}
