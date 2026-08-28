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
        let p = try SampleTrajectoryProvider(contentsOf: Self.trajectoryURL("ubiquitin"),
                                             recycles: .all)
        #expect(p.residueCount == 76)
        #expect(p.readouts.count == 32)
        // The default plays the first recycle only: one descent rather than the same fold
        // four times. See `SampleTrajectoryProvider.RecycleSelection`.
        #expect(try Self.provider("ubiquitin").readouts.count == 8)
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
        // Every recycle, because this measures sustained throughput and wants the longest
        // trajectory available rather than the default single descent.
        let provider = try SampleTrajectoryProvider(contentsOf: Self.trajectoryURL("beta2ar_7tm"),
                                                    recycles: .all)
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
        // Under a sanitizer the measurement is instrumentation overhead, not engine cost:
        // the same test measures 1.65 ms/frame in release, 207 ms under Thread Sanitizer and
        // 511 ms in debug. The TSan run exists to find data races, and asserting a timing
        // budget inside it would only produce a red test that means nothing. The runner sets
        // this variable; the measurement is still printed either way.
        if ProcessInfo.processInfo.environment["PHONEFOLD_SKIP_PERF_BUDGET"] == "1" {
            print("  (frame budget not asserted: PHONEFOLD_SKIP_PERF_BUDGET is set)")
            return
        }
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

    /// Flicker is a state that changes and changes *back*. A state that changes and stays
    /// changed is secondary structure forming, which is the entire subject of the app.
    ///
    /// This test used to count every change and require them to be under 1% of
    /// residue-frames, and it passed for the wrong reason: three quarters of a four-recycle
    /// trajectory is an already-settled structure where nothing changes, and those frames
    /// diluted the rate. Playing the first recycle alone - the part where the protein
    /// actually folds - took the same measurement from 0.74% to 1.94% without anything having
    /// got worse. Of the 88 changes over the whole ubiquitin run, 53 are in the first
    /// recycle's 36 frames and 35 are spread over the 120 settled ones.
    ///
    /// So the measurement is now reversals inside a short window, which is what the
    /// hysteresis exists to prevent and what an eye actually catches.
    @Test("secondary structure does not flicker between adjacent frames")
    func noFlicker() async throws {
        let provider = try Self.provider("ubiquitin")
        let engine = FoldEngine()
        var history: [[SecondaryStructure]] = []
        for await frame in try await engine.frames(for: provider) {
            history.append(frame.secondaryStructure.map(\.structure))
        }
        try #require(history.count > 10)

        // A reversal: residue r is X at frame i, not X at i+1, and X again within the window.
        let window = 6                                    // a tenth of a second at 60 fps
        var reversals = 0
        var changes = 0
        for i in 1..<history.count {
            for r in 0..<provider.residueCount where history[i][r] != history[i - 1][r] {
                changes += 1
                let restored = ((i + 1)...Swift.min(i + window, history.count - 1))
                    .contains { history[$0][r] == history[i - 1][r] }
                if restored { reversals += 1 }
            }
        }
        let opportunities = Double(history.count * provider.residueCount)
        print(String(format: "SS: %d changes, %d reversals over %.0f residue-frames "
                     + "(%.4f%% changed, %.4f%% reversed)",
                     changes, reversals, opportunities,
                     Double(changes) / opportunities * 100,
                     Double(reversals) / opportunities * 100))
        // Judged as a fraction of the changes, not of the residue-frames.
        //
        // A rate over residue-frames has the trajectory's length in its denominator, which is
        // what made the old measurement move by a factor of three when the playback default
        // changed and nothing about the geometry did. "What fraction of the changes did not
        // stick" has no such denominator: it says the same thing about a long fold and a
        // short one, and it is the question hysteresis is actually answering.
        //
        // Measured here: 53 changes, 6 of which reverse. Nearly nine in ten stick.
        #expect(Double(reversals) / Double(Swift.max(changes, 1)) < 0.25,
                "secondary structure is flickering: \(reversals) of \(changes) changes reversed")
        #expect(changes > 0, "a fold with no structure change at all would mean a dead assigner")
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

/// Which part of a recycled trajectory gets played.
@Suite("Recycle selection")
struct RecycleSelectionTests {

    static func bundle(recycles: Int, perRecycle: Int) -> TrajectoryBundle {
        let residues = 6
        let metadata = TrajectoryMetadata(
            name: "test", sequence: String(repeating: "A", count: residues),
            provenance: .testFixture, sourceModel: "none/test-fixture",
            blocksPerReadout: 1, recycles: recycles,
            generated: "2026-08-28T00:00:00Z")
        var readouts: [TrajectoryReadout] = []
        for recycle in 0..<recycles {
            for step in 0..<perRecycle {
                // Each recycle re-expands then contracts: the shape that puts the peaks in
                // the radius-of-gyration trace.
                let spread = Float(perRecycle - step)
                let backbone = (0..<residues).map { k -> BackboneResidue in
                    let base = SIMD3<Float>(Float(k) * 3.8, spread * 0.5, 0)
                    return BackboneResidue(n: base + SIMD3<Float>(-0.5, 0, 0), ca: base,
                                           c: base + SIMD3<Float>(0.5, 0, 0),
                                           o: base + SIMD3<Float>(0.9, 0.5, 0))
                }
                readouts.append(TrajectoryReadout(
                    recycle: recycle, blockIndex: step, backbone: backbone,
                    confidence: [Float](repeating: 80, count: residues)))
            }
        }
        return TrajectoryBundle(metadata: metadata, readouts: readouts)
    }

    @Test("The first recycle is the default, and it is one descent")
    func firstRecycleByDefault() throws {
        let provider = try SampleTrajectoryProvider(bundle: Self.bundle(recycles: 4,
                                                                       perRecycle: 8))
        #expect(provider.readouts.count == 8)
        #expect(provider.readouts.allSatisfy { $0.recycle == 0 })
    }

    @Test("Asking for all of it gets all of it")
    func allRecyclesOnRequest() throws {
        let provider = try SampleTrajectoryProvider(bundle: Self.bundle(recycles: 4,
                                                                        perRecycle: 8),
                                                    recycles: .all)
        #expect(provider.readouts.count == 32)
    }

    /// A diffusion trajectory has no recycles to choose between, and must come through whole.
    /// The bundled Genie 2 run is 201 readouts under a single recycle index; filtering it as
    /// if it were recycled would be the difference between a fold and nothing at all.
    @Test("A trajectory that does not recycle is played entire")
    func unrecycledTrajectoryIsUntouched() throws {
        let provider = try SampleTrajectoryProvider(bundle: Self.bundle(recycles: 1,
                                                                        perRecycle: 50))
        #expect(provider.readouts.count == 50)
    }
}
