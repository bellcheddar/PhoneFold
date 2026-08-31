import Testing
import Foundation
@testable import FoldCapture
import FoldCore
import FoldRender

/// The burned-in caption, and the framing that makes a vertical export work.
@Suite("Film overlay", .serialized)
struct FilmOverlayTests {

    @Test("the caption says what the trajectory is")
    func captionComposes() {
        var caption = FilmOverlay.Caption(
            name: "Hen egg white lysozyme", accession: "1LYZ", residueCount: 129,
            confidence: 94.1, confidenceSource: .pLDDT)
        let lines = caption.lines
        #expect(lines.title == "Hen egg white lysozyme")
        #expect(lines.detail.contains("1LYZ"))
        #expect(lines.detail.contains("129 residues"))
        // The confidence is named, not just printed: three of the four engines do not report
        // pLDDT, and a bare number under the wrong name is worse than no number.
        #expect(lines.detail.contains("pLDDT 94"))

        caption.confidenceSource = .nativeContacts
        #expect(caption.lines.detail.contains(ConfidenceSource.nativeContacts.displayName))
        #expect(!caption.lines.detail.contains("pLDDT"))
    }

    @Test("a generated backbone has no name to print, and says so")
    func captionHandlesMissingFields() {
        // Genie 2 invents a protein: no accession, no name, nothing to look up.
        let caption = FilmOverlay.Caption(residueCount: 64, provenance: "generated")
        let lines = caption.lines
        #expect(lines.title == "PhoneFold", "with nothing to name, the mark stands in")
        #expect(lines.detail.contains("64 residues"))
        #expect(lines.detail.contains("generated"))
        // And an empty caption produces no detail line rather than a row of separators.
        #expect(FilmOverlay.Caption().lines.detail.isEmpty)
    }

    @Test("the caption is drawn at the frame's own size")
    func overlayMatchesTheFrame() throws {
        let caption = FilmOverlay.Caption(name: "Test protein", residueCount: 42)
        for size in [OffscreenStage.Size.landscape, .vertical, .ultraHD] {
            let overlay = try #require(FilmOverlay(caption: caption, size: size))
            #expect(overlay.width == size.width)
            #expect(overlay.height == size.height)
            #expect(overlay.pixels.count == size.width * size.height * 4)
        }
    }

    @Test("type scales with the frame, so 4K is not a 1080p caption shrunk")
    func typeScales() throws {
        let caption = FilmOverlay.Caption(name: "Test protein", residueCount: 42)
        func inkedPixels(_ size: OffscreenStage.Size) throws -> Double {
            let overlay = try #require(FilmOverlay(caption: caption, size: size))
            var inked = 0
            for i in stride(from: 3, to: overlay.pixels.count, by: 4)
            where overlay.pixels[i] > 8 { inked += 1 }
            return Double(inked) / Double(size.width * size.height)
        }
        // The same caption should cover about the same *fraction* of the frame at any size.
        let hd = try inkedPixels(.landscape)
        let uhd = try inkedPixels(.ultraHD)
        #expect(hd > 0.0001, "nothing was drawn at 1080p")
        #expect(uhd > 0.0001, "nothing was drawn at 4K")
        #expect(abs(uhd - hd) < hd * 0.5, "1080p covers \(hd), 4K covers \(uhd)")
    }

    @Test("blending leaves the picture alone where the caption is transparent")
    func blendingIsLocal() throws {
        let caption = FilmOverlay.Caption(name: "Test", residueCount: 8)
        let size = OffscreenStage.Size(width: 640, height: 360)
        let overlay = try #require(FilmOverlay(caption: caption, size: size))

        var frame = [UInt8](repeating: 90, count: size.width * size.height * 4)
        let before = frame
        frame.withUnsafeMutableBufferPointer { raw in
            overlay.blend(into: raw.baseAddress!, bytesPerRow: size.width * 4)
        }
        // The top of the frame is where the protein is, and the caption is at the bottom.
        let topRow = 0
        let topUntouched = (0..<(size.width * 4)).allSatisfy {
            frame[topRow + $0] == before[topRow + $0]
        }
        #expect(topUntouched, "the caption changed pixels where it has nothing to draw")
        // And something changed somewhere, or the blend did nothing at all.
        #expect(frame != before)
    }

    // MARK: - Presets

    @Test("a frame narrower than it is tall stands the camera further back")
    func verticalFramingPullsBack() {
        // A 16:9 frame is limited by its height, which is what the field of view is measured
        // on, so the live distance is already right.
        #expect(OffscreenStage.aspectPullback(OffscreenStage.Size.landscape.aspect) == 1)
        #expect(OffscreenStage.aspectPullback(OffscreenStage.Size.ultraHD.aspect) == 1)
        // A 9:16 frame is limited by its width. Checked against the geometry: a protein 1.15
        // across needs 0.575 / (tan(21 degrees) * 0.5625) = 2.66 units where landscape needs
        // 1.5, and 1.5 * pullback should be that.
        let pullback = OffscreenStage.aspectPullback(OffscreenStage.Size.vertical.aspect)
        #expect(abs(1.5 * pullback - 2.66) < 0.1, "1.5 * \(pullback) is not 2.66")
        // And a degenerate aspect does not divide by zero into an infinite distance.
        #expect(OffscreenStage.aspectPullback(0).isFinite)
    }

    @MainActor
    @Test("the protein is in frame at every preset")
    func everyPresetFramesTheProtein() async throws {
        for size in [OffscreenStage.Size.landscape, .vertical, .ultraHD] {
            let stage = try OffscreenStage(size: size)
            let (mesh, confidence, options) = OffscreenStageTests.helix()
            try stage.show(mesh: mesh, confidence: confidence, mode: .secondaryStructure,
                           options: options)
            _ = try await stage.render()
            let pixels = stage.readPixels()
            let drawn = OffscreenStageTests.coverage(
                pixels, background: OffscreenStageTests.background(pixels))
            // Without the aspect pullback the vertical preset cuts the protein's sides off, or
            // fills the frame with it - either way the coverage leaves this band.
            #expect(drawn > 0.002, "\(size.width)x\(size.height) drew \(drawn * 100)%")
            #expect(drawn < 0.6, "\(size.width)x\(size.height) drew \(drawn * 100)%")
        }
    }
}
