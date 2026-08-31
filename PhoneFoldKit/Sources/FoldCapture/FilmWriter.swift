import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Metal

/// Writes frames and audio into a playable film.
///
/// PLAN.md Phase 4: "`AVAssetWriter` with `AVAssetWriterInputPixelBufferAdaptor` for video plus
/// an audio input... H.264 and HEVC. Presets: Landscape 1920x1080, Vertical 1080x1920, 4K
/// 3840x2160. 60 fps."
///
/// **Not real time.** `expectsMediaDataInRealTime` is false on both inputs, which is the whole
/// difference between this and a screen recording: the writer waits for the renderer rather
/// than the renderer racing the writer, so a slow frame costs seconds of export time instead of
/// a dropped frame in the film.
/// **One owner, used serially.** `AVAssetWriter` is not thread-safe and neither is this; the
/// contract is that a single export drives it from start to finish, which is what an export
/// is. Marked `@unchecked` rather than made an actor because every call would then be a
/// suspension point in the middle of a per-frame loop, for no concurrency that anyone wants.
public final class FilmWriter: @unchecked Sendable {

    public enum Codec: String, Sendable, CaseIterable {
        case h264
        case hevc
        // PLAN.md Phase 5a: ProRes for Studio, so a fold can be graded rather than watched.
        //
        // **Absent on visionOS rather than falling back**, because AVFoundation marks both
        // ProRes types `API_UNAVAILABLE(visionos)`. A case that quietly wrote H.264 when asked
        // for ProRes would be the worst of the three options: the file would be named .mov,
        // report success, and not be a master. Studio is where ProRes belongs anyway.
        #if !os(visionOS)
        case proRes422HQ
        case proRes4444
        #endif

        var videoCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            #if !os(visionOS)
            case .proRes422HQ: .proRes422HQ
            case .proRes4444: .proRes4444
            #endif
            }
        }

        /// Whether this is a mastering codec: intra-frame, constant quality, no bitrate to set.
        public var isProRes: Bool {
            switch self {
            case .h264, .hevc: false
            #if !os(visionOS)
            case .proRes422HQ, .proRes4444: true
            #endif
            }
        }

        /// **ProRes goes in a QuickTime container, not an MP4.** HEVC in an MP4 is fine, which
        /// is why this used to return `.mp4` for everything; ProRes in an MP4 is not a standard
        /// pairing, and the failure is the bad kind - the file writes without complaint and
        /// then will not open in the thing it was made for.
        public var fileType: AVFileType { isProRes ? .mov : .mp4 }

        /// The extension that matches the container. A `.mp4` holding QuickTime is a file that
        /// lies about itself to every tool that sniffs by extension.
        public var fileExtension: String { isProRes ? "mov" : "mp4" }

        /// What a person picking from a menu should see.
        public var displayName: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            #if !os(visionOS)
            case .proRes422HQ: "ProRes 422 HQ"
            case .proRes4444: "ProRes 4444"
            #endif
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case couldNotCreate(String)
        case cannotAddInput(String)
        case noPixelBufferPool
        case appendFailed(String)
        case finishFailed(String)

        public var description: String {
            switch self {
            case .couldNotCreate(let m): "Could not create the film: \(m)"
            case .cannotAddInput(let m): "The film cannot carry \(m)."
            case .noPixelBufferPool: "The writer gave out no pixel buffer pool."
            case .appendFailed(let m): "A frame could not be written: \(m)"
            case .finishFailed(let m): "The film could not be finished: \(m)"
            }
        }
    }

    public let url: URL
    public let size: OffscreenStage.Size
    public let frameRate: Int32
    public let codec: Codec
    public let sampleRate: Double

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private var frameIndex: Int64 = 0
    private var started = false
    private var audioFinished = false

    /// The caption burned into every frame, if there is one. Set before the first append.
    public var overlay: FilmOverlay?

    /// Bits per second for the video track.
    ///
    /// Scaled with the pixel rate rather than fixed, because a preset is a resolution and the
    /// same bitrate that is generous at 1080p is a smear at 4K. About 0.1 bits per pixel per
    /// frame, which is a comfortable place for synthetic content with large flat areas - a
    /// protein on a near-black stage compresses far better than camera footage.
    public static func bitrate(for size: OffscreenStage.Size, frameRate: Int32,
                               codec: Codec) -> Int {
        // ProRes is constant-quality and intra-frame: it has no bitrate to be told. Returning
        // zero rather than a plausible number, so a caller that uses this to size a disk budget
        // is obviously wrong rather than quietly wrong.
        guard !codec.isProRes else { return 0 }
        let pixels = Double(size.width * size.height) * Double(frameRate)
        // HEVC does the same job at roughly two thirds the rate.
        let perPixel = codec == .hevc ? 0.07 : 0.10
        return Int(pixels * perPixel)
    }

    public init(url: URL, size: OffscreenStage.Size, frameRate: Int32 = 60,
                codec: Codec = .h264, sampleRate: Double = 48_000,
                includesAudio: Bool = true) throws {
        self.url = url
        self.size = size
        self.frameRate = frameRate
        self.codec = codec
        self.sampleRate = sampleRate

        // A writer refuses to start if anything is already at the URL, and says so only when
        // `startWriting` fails - which is a long way from the cause.
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        } catch {
            throw Failure.couldNotCreate(error.localizedDescription)
        }

        // ProRes takes no bitrate and no key-frame interval: every frame is a key frame and
        // the quality is fixed by the variant. Handing it the inter-frame keys is at best
        // ignored and at worst refused, and neither is worth finding out at export time.
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.videoCodec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ]
        if !codec.isProRes {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Self.bitrate(for: size, frameRate: frameRate,
                                                       codec: codec),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate) * 2,
            ]
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(video) else { throw Failure.cannotAddInput("video") }
        writer.add(video)

        if includesAudio {
            // **Uncompressed audio alongside ProRes.** A mastering codec with a lossy
            // soundtrack is a strange object: the picture survives grading intact and the sound
            // has already been thrown away once before anyone touches it.
            let audioSettings: [String: Any] = codec.isProRes
                ? [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            track.expectsMediaDataInRealTime = false
            guard writer.canAdd(track) else { throw Failure.cannotAddInput("audio") }
            writer.add(track)
            audio = track
        } else {
            audio = nil
        }
    }

    // MARK: - Writing

    public func begin() throws {
        guard !started else { return }
        guard writer.startWriting() else {
            throw Failure.couldNotCreate(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    /// Append one rendered frame.
    ///
    /// The texture is `rgba8Unorm` and the pixel buffer is BGRA, so the copy swaps the red and
    /// blue channels. Getting that wrong does not fail - it produces a film in which the
    /// protein is cyan where it should be pink, which looks like a colour-mode bug rather than
    /// a byte order one.
    public func append(texture: MTLTexture) throws {
        try begin()
        guard let pool = adaptor.pixelBufferPool else { throw Failure.noPixelBufferPool }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixels = buffer
        else { throw Failure.appendFailed("no pixel buffer") }

        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            throw Failure.appendFailed("the pixel buffer has no base address")
        }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        // Straight into the pixel buffer's own rows, which may be padded: a texture read into
        // `width * 4` bytes per row and then memcpy'd would shear every frame on any device
        // whose pool pads.
        texture.getBytes(base, bytesPerRow: stride,
                         from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<size.height {
            let start = row * stride
            for column in 0..<size.width {
                let index = start + column * 4
                bytes.advanced(by: index).pointee ^= bytes.advanced(by: index + 2).pointee
                bytes.advanced(by: index + 2).pointee ^= bytes.advanced(by: index).pointee
                bytes.advanced(by: index).pointee ^= bytes.advanced(by: index + 2).pointee
            }
        }

        if let overlay, overlay.width == size.width, overlay.height == size.height {
            overlay.blend(into: bytes, bytesPerRow: stride)
        }

        let time = CMTime(value: frameIndex, timescale: frameRate)
        try Self.waitUntilReady(video, what: "video")
        guard adaptor.append(pixels, withPresentationTime: time) else {
            throw Failure.appendFailed(writer.error?.localizedDescription ?? "frame \(frameIndex)")
        }
        frameIndex += 1
    }

    /// Append the whole soundtrack, as interleaved stereo float samples.
    ///
    /// In one go rather than interleaved with the frames: an export is not a recording, and the
    /// piece is a couple of minutes of float at most - 17 MB for forty-five seconds - so there
    /// is nothing to be gained by streaming it and a synchronisation bug to be avoided.
    public func appendAudio(left: [Float], right: [Float]) throws {
        guard let audio else { return }
        try begin()
        let frames = Swift.min(left.count, right.count)
        guard frames > 0 else { return }

        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &description, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format
        else { throw Failure.appendFailed("could not describe the audio format") }

        let bytes = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block
        else { throw Failure.appendFailed("could not allocate an audio block") }
        _ = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample
        else { throw Failure.appendFailed("could not build an audio sample buffer") }

        try Self.waitUntilReady(audio, what: "audio")
        guard audio.append(sample) else {
            throw Failure.appendFailed(writer.error?.localizedDescription ?? "audio")
        }
        // Closed as soon as it is written.
        //
        // **`AVAssetWriter` interleaves its tracks**, and will not take more video once the
        // video is far enough ahead of an audio track that still expects data. Writing every
        // frame first and the sound afterwards therefore deadlocks on a long export - measured:
        // a 45-second film sat at 0.3% CPU for twenty-one minutes with a zero-byte file,
        // spinning in a readiness loop that would never come true. The soundtrack is one
        // buffer covering the whole timeline, so there is never more of it to write.
        audio.markAsFinished()
        audioFinished = true
    }

    /// Wait for an input to accept more data, and give up rather than hang.
    ///
    /// A bare `while !isReadyForMoreMediaData` is an unkillable spin when the writer is waiting
    /// for a track that will never be written. Ten seconds is far longer than an encoder needs
    /// to drain and far shorter than a person will wait wondering whether it has crashed.
    static func waitUntilReady(_ input: AVAssetWriterInput, what: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline {
                throw Failure.appendFailed(
                    "the \(what) input never became ready - the writer is probably waiting for "
                    + "another track")
            }
            usleep(1_000)
        }
    }

    /// Close the file.
    public func finish() async throws {
        try begin()
        video.markAsFinished()
        if !audioFinished { audio?.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure.finishFailed(writer.error?.localizedDescription
                                       ?? "status \(writer.status.rawValue)")
        }
    }

    /// How many frames have been written.
    public var writtenFrames: Int { Int(frameIndex) }
}
