import Foundation
import FoldCore
import FoldGeometry
import FoldRender

/// A fold as numbered PNGs, for anyone who wants to grade it.
///
/// PLAN.md Phase 5a: "ProRes and 4K export, plus an image-sequence export for anyone who wants
/// to grade it."
///
/// **A separate exporter rather than an option on the film, because the audience is different.**
/// Someone taking frames into a grading or compositing tool wants the frames and nothing else:
/// no soundtrack, no burned-in caption over the picture they are about to work on, and no
/// container decisions made for them. Bolting this onto `FilmExporter` would have meant a film
/// export that sometimes writes no film, and a caption that sometimes must not be drawn.
///
/// It still shares the one thing that matters: the same `OffscreenStage`, the same tube
/// geometry, the same colouring. The frames are the film's frames.
public struct ImageSequenceExporter: Sendable {

    public struct Options: Sendable {
        public var size: OffscreenStage.Size = .ultraHD
        public var frameRate: Int32 = 60
        public var colourMode: ColourMode = .secondaryStructure
        /// Burned in only if asked for. Off by default: a caption baked into a frame someone
        /// is about to grade is damage, not information.
        public var caption: FilmOverlay.Caption?
        /// Filename stem, numbered `stem.000001.png`. Six digits because a 45-second fold at
        /// 60 fps is 2,700 frames and a longer one at 4K is not unreasonable.
        public var stem = "frame"

        public init() {}
    }

    public struct Summary: Sendable, Equatable {
        public let directory: URL
        public let frames: Int
        public let size: OffscreenStage.Size
        public let frameRate: Int32

        /// What to type into ffmpeg to get a film back out. Written into the directory beside
        /// the frames, because the frame rate is the one thing a folder of PNGs cannot carry
        /// and the one thing that is wrong if it is guessed.
        public var readme: String {
            """
            \(frames) frames, \(size.width)x\(size.height), \(frameRate) fps.

            The frame rate is not recoverable from the files, so it is written here: an image
            sequence assembled at the wrong rate plays at the wrong speed and looks like a
            rendering fault rather than a mistake at import.

            ffmpeg -framerate \(frameRate) -i frame.%06d.png -c:v prores_ks -profile:v 3 out.mov
            """
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Render every frame to `directory` as a PNG.
    @MainActor
    public func export(frames: [FoldFrame], residues: [AminoAcid], to directory: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Summary {
        guard !frames.isEmpty else {
            throw FilmWriter.Failure.couldNotCreate("there are no frames to write")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stage = try OffscreenStage(size: options.size)
        let overlay = options.caption.flatMap { FilmOverlay(caption: $0, size: options.size) }
        let step = 1 / Float(options.frameRate)
        let colourOptions = ColourOptions(residueCount: residues.count, residues: residues)

        for (index, frame) in frames.enumerated() {
            let mesh = TubeGeometry.build(caPositions: frame.backbone.map(\.ca),
                                          secondaryStructure: frame.secondaryStructure)
            try stage.show(mesh: mesh, confidence: frame.pLDDT, mode: options.colourMode,
                           options: colourOptions)
            stage.advance(by: step)
            _ = try await stage.render()

            var pixels = stage.readPixels()
            if let overlay {
                pixels.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    overlay.blend(into: base, bytesPerRow: options.size.width * 4)
                }
            }
            guard let png = OffscreenStage.png(pixels: pixels, size: options.size) else {
                throw FilmWriter.Failure.couldNotCreate("frame \(index) would not encode as PNG")
            }
            // Zero-padded and fixed width, so the shell and every importer sort them in the
            // order they were rendered rather than 1, 10, 100, 2.
            let name = String(format: "%@.%06d.png", options.stem, index)
            try png.write(to: directory.appending(path: name))
            progress?(Double(index + 1) / Double(frames.count))
        }

        let summary = Summary(directory: directory, frames: frames.count,
                              size: options.size, frameRate: options.frameRate)
        try summary.readme.write(to: directory.appending(path: "README.txt"),
                                 atomically: true, encoding: .utf8)
        return summary
    }
}
