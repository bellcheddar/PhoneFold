import Testing
import Foundation
import AVFoundation
import simd
@testable import FoldCapture
import FoldCore
import FoldGeometry
import FoldRender

/// The film. PLAN.md's Phase 4 gate is "offscreen export produces a valid MP4 with audio from a
/// sample trajectory" and "MP4 probes clean", so what these have to prove is that a real file
/// comes out and that `AVFoundation` will read it back.
@Suite("Film writer", .serialized)
struct FilmWriterTests {

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "phonefold-test-\(name)-\(UUID().uuidString).mp4")
    }

    /// A short piece of music: a rising tone, so a silent track is obvious.
    static func tone(seconds: Double, sampleRate: Double = 48_000) -> ([Float], [Float]) {
        let frames = Int(seconds * sampleRate)
        let samples = (0..<frames).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(0.3 * sin(2 * .pi * (220 + 220 * t) * t))
        }
        return (samples, samples)
    }

    @MainActor
    static func stage(_ size: OffscreenStage.Size) throws -> OffscreenStage {
        let stage = try OffscreenStage(size: size)
        let (mesh, confidence, options) = OffscreenStageTests.helix()
        try stage.show(mesh: mesh, confidence: confidence, mode: .secondaryStructure,
                       options: options)
        return stage
    }

    // MARK: -

    @MainActor
    @Test("a fold becomes an MP4 that AVFoundation will read back")
    func writesAPlayableFilm() async throws {
        let url = Self.temporaryURL("playable")
        defer { try? FileManager.default.removeItem(at: url) }

        let size = OffscreenStage.Size(width: 640, height: 360)
        let stage = try Self.stage(size)
        let writer = try FilmWriter(url: url, size: size, frameRate: 30)
        // One second at 30 fps.
        for _ in 0..<30 {
            _ = try await stage.render()
            try writer.append(texture: stage.texture)
        }
        let (left, right) = Self.tone(seconds: 1)
        try writer.appendAudio(left: left, right: right)
        try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        // **Not a file-size threshold.** The first version asserted 10 kB and the file came out
        // at 8,769 - not because anything was wrong but because thirty frames of a near-black
        // stage compress to almost nothing. Size measures the encoder's luck, not the film.

        // Read it back with AVFoundation, which is what "probes clean" means.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.2,
                "duration \(CMTimeGetSeconds(duration)) s")

        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1, "no video track")
        #expect(audio.count == 1, "no audio track - the film is silent")

        let dimensions = try await video[0].load(.naturalSize)
        #expect(Int(dimensions.width) == size.width)
        #expect(Int(dimensions.height) == size.height)
        let rate = try await video[0].load(.nominalFrameRate)
        #expect(abs(rate - 30) < 1, "\(rate) fps")

        // Both tracks run the full second - an audio track that exists but stops after a frame
        // would pass every assertion above.
        let videoSpan = try await video[0].load(.timeRange).duration
        let audioSpan = try await audio[0].load(.timeRange).duration
        #expect(abs(CMTimeGetSeconds(videoSpan) - 1.0) < 0.05)
        #expect(abs(CMTimeGetSeconds(audioSpan) - 1.0) < 0.05)

        // And the audio is sound rather than a second of silence, which is what a mis-built
        // sample buffer produces: the right length, the right format, and nothing in it.
        let level = try await Self.audioLevel(of: asset)
        #expect(level > 0.01, "the film's audio is silent (RMS \(level))")
    }

    /// Root-mean-square of a film's audio, decoded back out of it.
    static func audioLevel(of asset: AVURLAsset) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var sum = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for i in 0..<(length / 4) {
                    sum += Double(floats[i]) * Double(floats[i])
                    count += 1
                }
            }
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    @MainActor
    @Test("both codecs produce a readable film")
    func bothCodecsWork() async throws {
        for codec in FilmWriter.Codec.allCases {
            let url = Self.temporaryURL(codec.rawValue)
            defer { try? FileManager.default.removeItem(at: url) }
            let size = OffscreenStage.Size(width: 640, height: 360)
            let stage = try Self.stage(size)
            let writer = try FilmWriter(url: url, size: size, frameRate: 30, codec: codec)
            for _ in 0..<15 {
                _ = try await stage.render()
                try writer.append(texture: stage.texture)
            }
            try await writer.finish()

            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            #expect(tracks.count == 1, "\(codec.rawValue) produced no video track")
            let formats = try await tracks[0].load(.formatDescriptions)
            let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
            let expected = codec == .hevc
                ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            #expect(subtype == expected, "\(codec.rawValue) wrote the wrong codec")
        }
    }

    @Test("the bitrate scales with the pixel rate rather than being fixed")
    func bitrateScales() {
        // The same rate that is generous at 1080p is a smear at 4K.
        let hd = FilmWriter.bitrate(for: .landscape, frameRate: 60, codec: .h264)
        let uhd = FilmWriter.bitrate(for: .ultraHD, frameRate: 60, codec: .h264)
        #expect(uhd > hd * 3, "4K is four times the pixels")
        // And HEVC does the same job at a lower rate.
        #expect(FilmWriter.bitrate(for: .landscape, frameRate: 60, codec: .hevc) < hd)
        // Halving the frame rate halves the bits.
        #expect(abs(FilmWriter.bitrate(for: .landscape, frameRate: 30, codec: .h264) - hd / 2)
                < hd / 20)
    }

    @MainActor
    @Test("red and blue are not swapped")
    func channelsAreNotSwapped() async throws {
        // The texture is RGBA and the pixel buffer is BGRA. Getting that wrong does not fail -
        // it produces a film in which a pink helix is cyan, which reads as a colour-mode bug.
        let url = Self.temporaryURL("channels")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = OffscreenStage.Size(width: 320, height: 240)
        let stage = try Self.stage(size)
        _ = try await stage.render()
        let rendered = stage.readPixels()

        let writer = try FilmWriter(url: url, size: size, frameRate: 30, includesAudio: false)
        for _ in 0..<10 { try writer.append(texture: stage.texture) }
        try await writer.finish()

        // **Compared against the render, not against each other.** The first version asked
        // whether the film was red-dominant, which measures the background: a 320 by 240 frame
        // is mostly the indigo stage, whose blue channel outweighs every pixel of pink helix
        // in it. What matters is that the film's channels match the render's.
        var red = 0.0, blue = 0.0
        for i in stride(from: 0, to: rendered.count, by: 4) {
            red += Double(rendered[i])
            blue += Double(rendered[i + 2])
        }
        #expect(red > 0 && blue > 0)

        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var filmRed = 0.0, filmBlue = 0.0
        for row in 0..<CVPixelBufferGetHeight(pixels) {
            for column in 0..<CVPixelBufferGetWidth(pixels) {
                let i = row * stride + column * 4
                filmBlue += Double(base[i])        // BGRA
                filmRed += Double(base[i + 2])
            }
        }
        // Compression moves the numbers a little; a channel swap moves them a long way.
        let renderRatio = red / blue
        let filmRatio = filmRed / filmBlue
        #expect(abs(filmRatio - renderRatio) < renderRatio * 0.25,
                "render red/blue \(renderRatio), film \(filmRatio) - the channels are swapped")
    }
}
