import Testing
import Foundation
import simd
@testable import FoldCore
@testable import FoldCapture

@Suite("Image sequence export")
struct ImageSequenceExporterTests {

    static func frames(_ count: Int, residues: Int = 12) -> [FoldFrame] {
        (0..<count).map { index in
            let backbone = (0..<residues).map { i -> BackboneResidue in
                let t = Double(i) * 1.75 + Double(index) * 0.05
                let ca = SIMD3<Float>(Float(2.3 * cos(t)), Float(2.3 * sin(t)),
                                      Float(i) * 1.5)
                return BackboneResidue(n: ca, ca: ca, c: ca, o: ca)
            }
            return FoldFrame(
                index: index, recycle: 0, blockIndex: index, backbone: backbone,
                pLDDT: [Float](repeating: 85, count: residues),
                secondaryStructure: (0..<residues).map { _ in
                    SSAssignment(structure: .helix, confidence: 1)
                },
                newContacts: [], radiusOfGyration: 8, meanPLDDT: 85,
                isInterpolated: false)
        }
    }

    static var residues: [AminoAcid] { [AminoAcid](repeating: .alanine, count: 12) }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pf-seq-\(UUID().uuidString.prefix(8))")
    }

    @MainActor
    @Test("every frame becomes a PNG, numbered so they sort in render order")
    func writesNumberedFrames() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var options = ImageSequenceExporter.Options()
        options.size = OffscreenStage.Size(width: 320, height: 180)
        let summary = try await ImageSequenceExporter(options: options)
            .export(frames: Self.frames(12), residues: Self.residues, to: directory)

        #expect(summary.frames == 12)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }.sorted()
        #expect(pngs.count == 12)
        #expect(pngs.first == "frame.000000.png")
        #expect(pngs.last == "frame.000011.png")

        // Zero padding is the whole point: unpadded names sort 1, 10, 11, 2 and an importer
        // assembles the film in that order without complaining.
        #expect(pngs == pngs.sorted(), "lexical order is render order")
    }

    /// A folder of PNGs cannot carry a frame rate, and a sequence assembled at the wrong rate
    /// plays at the wrong speed and looks like a rendering fault.
    @Test("the frame rate is written down, because the files cannot carry it")
    func readmeCarriesTheFrameRate() {
        let summary = ImageSequenceExporter.Summary(
            directory: URL(fileURLWithPath: "/tmp/x"), frames: 2700,
            size: .ultraHD, frameRate: 60)
        #expect(summary.readme.contains("2700 frames"))
        #expect(summary.readme.contains("3840x2160"))
        #expect(summary.readme.contains("60 fps"))
        #expect(summary.readme.contains("-framerate 60"))
    }

    @MainActor
    @Test("the README lands beside the frames")
    func readmeIsWritten() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ImageSequenceExporter.Options()
        options.size = OffscreenStage.Size(width: 320, height: 180)
        _ = try await ImageSequenceExporter(options: options)
            .export(frames: Self.frames(3), residues: Self.residues, to: directory)
        let readme = directory.appending(path: "README.txt")
        #expect(FileManager.default.fileExists(atPath: readme.path))
        #expect(try String(contentsOf: readme, encoding: .utf8).contains("60 fps"))
    }

    @MainActor
    @Test("an empty trajectory is refused rather than writing an empty folder")
    func emptyIsRefused() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: FilmWriter.Failure.self) {
            _ = try await ImageSequenceExporter()
                .export(frames: [], residues: Self.residues, to: directory)
        }
    }

    /// The frames are meant to be graded, so by default nothing is drawn over them.
    @MainActor
    @Test("no caption is burned in unless one is asked for")
    func captionIsOptIn() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ImageSequenceExporter.Options()
        options.size = OffscreenStage.Size(width: 320, height: 180)
        #expect(options.caption == nil, "grading frames are clean by default")
        let plain = try await ImageSequenceExporter(options: options)
            .export(frames: Self.frames(2), residues: Self.residues, to: directory)
        #expect(plain.frames == 2)
    }
}
