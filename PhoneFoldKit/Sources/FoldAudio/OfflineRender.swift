import Foundation
import FoldCore

/// Renders a whole score to samples, and writes them as a WAV.
///
/// PLAN.md Phase 3 asks for a command-line renderer "that turns a sample trajectory plus a
/// style profile into a WAV. This lets the loop regression-test audio without a device, and
/// lets Marc audition style tweaks in seconds." This is that renderer; the command-line tool is
/// a thin wrapper over it, and so are the tests.
///
/// It drives the same `ScorePlayer` the live engine will, so the file is the piece rather than
/// an approximation of it.
public struct OfflineRender: Sendable {

    /// Interleaved stereo, plus what the run measured about itself.
    public struct Result: Sendable {
        public var left: [Float]
        public var right: [Float]
        public let sampleRate: Double
        /// Largest absolute sample, over both channels. Above 1 would be clipping.
        public let peak: Float
        /// Root-mean-square over both channels, as a level rather than a loudness.
        public let rms: Float
        /// Integrated loudness, ITU-R BS.1770-4, in LUFS.
        public let loudness: Double
        public let starvedBeats: Int
        public let refusedNotes: Int

        public var frameCount: Int { Swift.min(left.count, right.count) }
        public var duration: Double { Double(frameCount) / sampleRate }
    }

    public var sampleRate: Double
    public var masterGain: Double
    /// Seconds of silence left at the end for the last notes to ring out. Without it a piece
    /// ends by cutting its own reverb tail off, which reads as a fault rather than an ending.
    public var tail: Double

    /// How far ahead of the playhead the renderer is allowed to queue.
    ///
    /// The offline path feeds the player the way the live app does - a moment at a time as its
    /// beat approaches - rather than pushing the whole score in at once. Pushing it all in
    /// would overflow the queue and refuse most of it, and would exercise none of the jitter
    /// buffer's behaviour, which is half of what the offline render exists to check.
    public var lookahead: Double

    public init(sampleRate: Double = 48_000, masterGain: Double = 0.5, tail: Double = 2.5,
                lookahead: Double = 4) {
        self.sampleRate = sampleRate
        self.masterGain = masterGain
        self.tail = tail
        self.lookahead = lookahead
    }

    /// Render every moment of a score.
    public func render(_ score: [ScoreMoment], style: StyleProfile,
                       residueCount: Int) -> Result {
        var player = ScorePlayer(style: style, residueCount: residueCount,
                                 sampleRate: sampleRate, masterGain: masterGain)

        // How long the piece runs: every bar at its own tempo, plus the tail.
        var seconds = tail
        for moment in score { seconds += MusicalClock.momentDuration(tempo: moment.tempo) }
        let frames = Swift.max(Int(seconds * sampleRate), 1)

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        // A block at a time, feeding the clock as it drains - which is how the live path runs,
        // and the only way the jitter buffer's behaviour gets exercised offline at all.
        let block = 512
        var next = 0
        var offset = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                while offset < frames {
                    while next < score.count, player.nextBeat < player.elapsed + lookahead {
                        player.submit(score[next])
                        next += 1
                    }
                    let end = Swift.min(offset + block, frames)
                    player.render(left: UnsafeMutableBufferPointer(rebasing: l[offset..<end]),
                                  right: UnsafeMutableBufferPointer(rebasing: r[offset..<end]))
                    offset = end
                }
            }
        }

        var peak: Float = 0
        var square = 0.0
        for i in 0..<frames {
            peak = Swift.max(peak, Swift.max(abs(left[i]), abs(right[i])))
            square += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i])
        }
        let rms = Float((square / Double(Swift.max(frames * 2, 1))).squareRoot())

        return Result(left: left, right: right, sampleRate: sampleRate, peak: peak, rms: rms,
                      loudness: Self.integratedLoudness(left: left, right: right,
                                                        sampleRate: sampleRate),
                      starvedBeats: player.starvedBeats, refusedNotes: player.refusedNotes)
    }

    // MARK: - Loudness

    /// Integrated loudness in LUFS, ITU-R BS.1770-4.
    ///
    /// The K-weighting filter, mean square over 400 ms blocks, and the two-stage gate: an
    /// absolute gate at -70 LUFS, then a relative gate 10 LU below the mean of what survived
    /// it. The gating is the part that matters and the part usually left out - without it a
    /// piece that opens quietly reads as much quieter than it sounds, because the silence is
    /// averaged in with the music.
    ///
    /// Coefficients are the standard's own, at 48 kHz. At another sample rate they are wrong,
    /// so this says so rather than quietly reporting a number: any other rate returns `nan`.
    public static func integratedLoudness(left: [Float], right: [Float],
                                          sampleRate: Double) -> Double {
        guard abs(sampleRate - 48_000) < 1, !left.isEmpty else { return .nan }
        let a = kWeighted(left), b = kWeighted(right)
        let frames = Swift.min(a.count, b.count)

        // 400 ms blocks, 75% overlap, as the standard specifies.
        let blockSize = Int(0.4 * sampleRate)
        let step = blockSize / 4
        guard frames >= blockSize else { return .nan }

        var blocks: [Double] = []
        var start = 0
        while start + blockSize <= frames {
            var sum = 0.0
            for i in start..<(start + blockSize) {
                sum += Double(a[i]) * Double(a[i]) + Double(b[i]) * Double(b[i])
            }
            blocks.append(sum / Double(blockSize))
            start += step
        }
        guard !blocks.isEmpty else { return .nan }

        func level(_ meanSquare: Double) -> Double {
            meanSquare <= 0 ? -.infinity : -0.691 + 10 * log10(meanSquare)
        }

        // Absolute gate.
        let aboveAbsolute = blocks.filter { level($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let meanAbsolute = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        // Relative gate, 10 LU below that mean.
        let threshold = level(meanAbsolute) - 10
        let gated = aboveAbsolute.filter { level($0) > threshold }
        guard !gated.isEmpty else { return level(meanAbsolute) }
        return level(gated.reduce(0, +) / Double(gated.count))
    }

    /// The two stages of BS.1770 K-weighting: a high-shelf, then a high-pass.
    static func kWeighted(_ input: [Float]) -> [Float] {
        // Stage 1, the shelving filter, and stage 2, the RLB high-pass. Both at 48 kHz.
        let shelf = (b: [1.53512485958697, -2.69169618940638, 1.19839281085285],
                     a: [1.0, -1.69065929318241, 0.73248077421585])
        let highPass = (b: [1.0, -2.0, 1.0],
                        a: [1.0, -1.99004745483398, 0.99007225036621])
        return biquad(biquad(input, shelf.b, shelf.a), highPass.b, highPass.a)
    }

    static func biquad(_ input: [Float], _ b: [Double], _ a: [Double]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in input.indices {
            let x0 = Double(input[i])
            let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            output[i] = Float(y0)
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }

    // MARK: - WAV

    /// 16-bit PCM stereo WAV.
    ///
    /// Written by hand rather than through `AVAudioFile` so the offline path stays free of any
    /// platform framework and can run anywhere the package builds - including in a test on a
    /// machine with no audio device at all.
    public static func wav(left: [Float], right: [Float], sampleRate: Double) -> Data {
        let frames = Swift.min(left.count, right.count)
        let channels = 2
        let bitsPerSample = 16
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = frames * blockAlign

        var data = Data(capacity: 44 + dataBytes)
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(Int(sampleRate)); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        ascii("data"); u32(dataBytes)

        var samples = [Int16](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            // 32767 rather than 32768: scaling by 32768 makes -1.0 valid and +1.0 overflow,
            // which shows up as a single inverted sample at the loudest moment of the piece.
            samples[i * 2] = Int16(Swift.max(-1, Swift.min(1, left[i])) * 32767)
            samples[i * 2 + 1] = Int16(Swift.max(-1, Swift.min(1, right[i])) * 32767)
        }
        samples.withUnsafeBufferPointer {
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!)
                .assumingMemoryBound(to: UInt8.self), count: dataBytes))
        }
        return data
    }
}
