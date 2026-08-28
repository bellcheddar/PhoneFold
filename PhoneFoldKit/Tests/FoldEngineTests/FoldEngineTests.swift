import Testing
import Foundation
import simd
import FoldCore
import FoldGeometry
@testable import FoldEngine

@Suite("Fold engine and frame stream")
struct FoldEngineTests {

    static func trajectoryURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/\(name).pftraj")
    }

    static func provider(_ name: String) throws -> SampleTrajectoryProvider {
        try SampleTrajectoryProvider(contentsOf: trajectoryURL(name))
    }

    @Test("a bundled trajectory loads through the provider")
    func loads() throws {
        let p = try Self.provider("ubiquitin")
        #expect(p.residueCount == 76)
        #expect(p.readouts.count == 32)
        #expect(p.confidenceSource == .pLDDT)
        #expect(p.isGenerated == false)

        let generated = try Self.provider("genie2_76aa_seed1")
        #expect(generated.isGenerated)
        #expect(generated.confidenceSource == .denoisingProgress)
    }

    @Test("an empty trajectory is refused rather than played")
    func refusesEmpty() async throws {
        let engine = FoldEngine()
        await #expect(throws: FoldEngineError.self) { try await engine.frames() }
    }

    /// The Phase 1 gate: a bundled trajectory plays end to end from the sample provider.
    @Test("a trajectory plays end to end and every frame is well formed")
    func playsEndToEnd() async throws {
        let provider = try Self.provider("genie2_76aa_seed1")
        let engine = FoldEngine()
        let sequence = try await engine.frames(for: provider)

        var count = 0
        var lastIndex = -1
        var raw = 0
        for await frame in sequence {
            #expect(frame.isWellFormed, "frame \(frame.index) is not well formed")
            #expect(frame.index == lastIndex + 1, "frames must arrive in order")
            #expect(frame.residueCount == provider.residueCount)
            let (h, e, c) = frame.structureFractions
            #expect(abs(h + e + c - 1) < 1e-4)
            if !frame.isInterpolated { raw += 1 }
            lastIndex = frame.index
            count += 1
        }
        #expect(count == sequence.frameCount)
        #expect(count > 1000, "expected a few thousand frames at 60 fps, got \(count)")
        #expect(raw == provider.readouts.count,
                "every raw readout should appear exactly once, got \(raw)")
    }

    /// The gate's frame-rate criterion, expressed as a budget rather than a stopwatch: a
    /// 300-residue input must produce a full 60 fps stream, and do it fast enough that the
    /// per-frame cost leaves room for rendering.
    ///
    /// **Only meaningful in release.** Measured on the M1 Max, this engine runs at
    /// 1.65 ms/frame built `-c release` and 511 ms/frame built debug: a factor of 310. Swift
    /// without optimisation is not slow-but-comparable for numeric code, it is a different
    /// order of magnitude, and a budget asserted in a debug build measures nothing useful.
    /// The debug bound below only catches a catastrophic regression.
    @Test("a 300-residue input sustains a 60 fps frame budget")
    func sustains60fps() async throws {
        let provider = try Self.provider("beta2ar_7tm")      // 314 residues
        #expect(provider.residueCount == 314)
        let engine = FoldEngine(configuration: .init(frameRate: 60, secondsPerRawFrame: 0.25))
        let sequence = try await engine.frames(for: provider)

        let start = Date()
        var count = 0
        for await frame in sequence {
            #expect(frame.isWellFormed)
            count += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        let perFrame = elapsed / Double(count) * 1000
        print(String(format: "314 residues: %d frames in %.1f s, %.2f ms/frame",
                     count, elapsed, perFrame))
        #expect(count > 400)
        // 16.7 ms is the 60 fps budget for everything; the engine must be a fraction of it.
        #if DEBUG
        // Debug builds are ~310x slower here; this only catches a catastrophic regression.
        #expect(perFrame < 3000, "engine regressed badly even allowing for a debug build")
        #else
        #expect(perFrame < 16.7, "engine exceeded the 16.7 ms per-frame budget for 60 fps")
        #endif
    }

    /// Contacts drive note onsets, so a contact must fire once, on a raw frame, and never on
    /// an interpolated one. Otherwise one contact becomes a burst of sixty.
    @Test("contact events fire only on raw frames, once each")
    func contactsOnlyOnRawFrames() async throws {
        let provider = try Self.provider("genie2_76aa_seed1")
        let engine = FoldEngine()
        var seen: Set<String> = []
        var duplicates = 0
        var onInterpolated = 0
        for await frame in try await engine.frames(for: provider) {
            if frame.isInterpolated && !frame.newContacts.isEmpty { onInterpolated += 1 }
            for contact in frame.newContacts {
                let key = "\(contact.i)-\(contact.j)"
                if !seen.insert(key).inserted { duplicates += 1 }
            }
        }
        #expect(onInterpolated == 0, "contacts fired on \(onInterpolated) interpolated frames")
        #expect(seen.count > 20, "expected real contact formation, got \(seen.count)")
        // A pair may legitimately break and re-form, but not often on a converging fold.
        #expect(duplicates < seen.count / 4)
    }

    @Test("the same trajectory produces byte-identical frames across runs")
    func deterministic() async throws {
        func run() async throws -> [Int] {
            let engine = FoldEngine()
            var signature: [Int] = []
            for await frame in try await engine.frames(for: try Self.provider("ubiquitin")) {
                signature.append(frame.newContacts.count)
                signature.append(frame.secondaryStructure.filter { $0.structure == .helix }.count)
            }
            return signature
        }
        let a = try await run()
        let b = try await run()
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test("cancellation stops the stream promptly")
    func cancellation() async throws {
        let provider = try Self.provider("beta2ar_7tm")
        let engine = FoldEngine()
        let sequence = try await engine.frames(for: provider)

        let task = Task { () -> Int in
            var count = 0
            for await _ in sequence {
                count += 1
                if count == 25 { break }
            }
            return count
        }
        #expect(await task.value == 25)
    }

    @Test("confidence is interpolated without overshooting its bounds")
    func confidenceStaysInRange() async throws {
        let provider = try Self.provider("genie2_76aa_seed1")
        let engine = FoldEngine()
        for await frame in try await engine.frames(for: provider) {
            for value in frame.pLDDT {
                #expect(value >= -0.01 && value <= 100.01,
                        "confidence \(value) escaped its range on frame \(frame.index)")
            }
        }
    }

    @Test("secondary structure does not flicker between adjacent frames")
    func noFlicker() async throws {
        let provider = try Self.provider("ubiquitin")
        let engine = FoldEngine()
        var previous: [SSAssignment]?
        var changes = 0
        var frames = 0
        for await frame in try await engine.frames(for: provider) {
            if let previous {
                for (a, b) in zip(previous, frame.secondaryStructure)
                where a.structure != b.structure { changes += 1 }
            }
            previous = frame.secondaryStructure
            frames += 1
        }
        // With hysteresis, state changes should be rare relative to frames x residues.
        let opportunities = Double(frames * provider.residueCount)
        let rate = Double(changes) / opportunities
        print(String(format: "SS state changes: %d over %.0f residue-frames (%.4f%%)",
                     changes, opportunities, rate * 100))
        #expect(rate < 0.01, "secondary structure is flickering")
    }

    @Test("every bundled trajectory plays without a malformed frame")
    func allBundledTrajectories() async throws {
        let dir = Self.trajectoryURL("x").deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pftraj" }.sorted { $0.path < $1.path }
        #expect(files.count >= 13)
        for file in files {
            let provider = try SampleTrajectoryProvider(contentsOf: file)
            let engine = FoldEngine(configuration: .init(frameRate: 12,
                                                         secondsPerRawFrame: 0.25))
            var count = 0
            for await frame in try await engine.frames(for: provider) {
                #expect(frame.isWellFormed,
                        "\(file.lastPathComponent) frame \(frame.index) malformed")
                count += 1
            }
            #expect(count > 0, "\(file.lastPathComponent) produced no frames")
        }
    }
}
