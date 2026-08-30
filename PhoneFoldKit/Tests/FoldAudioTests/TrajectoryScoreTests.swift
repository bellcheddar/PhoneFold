import Testing
import Foundation
import simd
@testable import FoldAudio
import FoldCore
import FoldEngine

/// The sonifier run over trajectories that really exist.
///
/// Synthetic frames prove the mapping's rules. They cannot prove it survives the shapes the
/// engines actually produce - a contact burst that empties the bar, a confidence curve that
/// never plateaus, a chain so long every texture voice saturates. These run the real thing,
/// which is the only place those show up, and both classes of trajectory are here because they
/// are genuinely different:
///
/// - The **gallery** `.pftraj` files are eight ESMFold readouts from the tail of one recycle.
///   They open already folded - readout 0 carries the whole contact map, and pLDDT jumps to
///   its final value on readout 1 and then sits flat. They are structures being refined, not
///   proteins folding, which is why the app now defaults to simulating instead.
/// - A **live** engine run is 180 readouts from a genuinely unfolded chain. That is the
///   default path, and the one the mapping's constants were measured against.
@Suite("Trajectory scores")
struct TrajectoryScoreTests {

    static var trajectoryDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "Apps/PhoneFold/Resources")
    }

    /// The bundled trajectories, by name, skipping any iCloud has evicted.
    ///
    /// Eviction is a real condition on this machine, not a hypothetical: Optimize Mac Storage
    /// turns files under Documents into dataless stubs. A test that failed on it would be
    /// reporting the storage setting, not the code.
    static func trajectories() throws -> [(name: String, bundle: TrajectoryBundle)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: trajectoryDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return try urls.filter { $0.pathExtension == "pftraj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0 else { return nil }
                return (url.deletingPathExtension().lastPathComponent,
                        try TrajectoryBundleCodec.read(contentsOf: url))
            }
    }

    static func frames(for bundle: TrajectoryBundle) async throws -> [FoldFrame] {
        let provider = try SampleTrajectoryProvider(bundle: bundle)
        var frames: [FoldFrame] = []
        for try await frame in FoldFrameSequence(provider: provider) { frames.append(frame) }
        return frames
    }

    /// A live fold toward a bundled trajectory's own final structure.
    static func liveFold(_ name: String, engine: FoldingEngine,
                         steps: Int? = nil) async throws -> (TrajectoryBundle, [FoldFrame]) {
        let url = trajectoryDirectory.appending(path: "\(name).pftraj")
        let reference = try TrajectoryBundleCodec.read(contentsOf: url)
        let last = try #require(reference.readouts.last)
        let native = last.caPositions.map {
            SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
        }
        let bundle = try LiveTrajectory.fold(engine: engine, native: native,
                                             metadata: reference.metadata,
                                             residues: reference.residues,
                                             seed: 1, steps: steps, frameCount: 180)
        return (bundle, try await frames(for: bundle))
    }

    static var style: StyleProfile {
        get throws {
            let loaded = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
            return try #require(loaded["fantasy"])
        }
    }

    /// Every invariant a moment must satisfy to be playable at all.
    static func check(_ score: [ScoreMoment], residues: Int, style: StyleProfile,
                      name: String) throws {
        #expect(!score.isEmpty, "\(name) produced no music")
        #expect(score.allSatisfy { !$0.notes.isEmpty }, "\(name) has silent bars")
        for moment in score {
            for note in moment.notes {
                for residue in note.spatialResidues {
                    #expect((0..<residues).contains(residue),
                            "\(name) placed a note on residue \(residue)")
                }
                #expect(note.note.pitch >= 12 && note.note.pitch <= 120,
                        "\(name) asked for MIDI \(note.note.pitch)")
                #expect(note.beatOffset >= 0 && note.beatOffset < Sonifier.beatsPerBar)
                #expect(note.duration > 0)
            }
            #expect(moment.tempo >= style.tempoSlow && moment.tempo <= style.tempoFast)
            #expect(moment.timbre.cutoff.isFinite && moment.timbre.cutoff > 0)
            #expect(moment.compaction >= 0 && moment.compaction <= 1)
        }
    }

    // MARK: - The gallery

    @Test("every bundled trajectory produces a playable score")
    func galleryTrajectoriesScore() async throws {
        let style = try Self.style
        let bundles = try Self.trajectories()
        #expect(!bundles.isEmpty, "no trajectories found in \(Self.trajectoryDirectory.path)")

        for (name, bundle) in bundles {
            let frames = try await Self.frames(for: bundle)
            let score = Sonifier.score(style: style, residues: bundle.residues, frames: frames)
            // One moment per raw readout, not per rendered frame.
            let raw = frames.filter { !$0.isInterpolated }.count
            #expect(score.count == raw, "\(name): \(score.count) moments for \(raw) readouts")
            try Self.check(score, residues: bundle.residues.count, style: style, name: name)

            // Only the opening bar reports established contacts, and only it.
            let established = score.filter { $0.establishedContacts > 0 }
            #expect(established.count <= 1)
            #expect(score.dropFirst().allSatisfy { $0.establishedContacts == 0 })
        }
    }

    @Test("what resolves, cadences; what stays disordered, does not")
    func cadenceTracksResolution() async throws {
        let style = try Self.style
        let tonic = try #require(style.progression.last)
        var cadenced: Set<String> = []

        for (name, bundle) in try Self.trajectories() {
            let frames = try await Self.frames(for: bundle)
            let score = Sonifier.score(style: style, residues: bundle.residues, frames: frames)
            let cadences = score.filter(\.isCadence)
            #expect(cadences.count <= 1, "\(name) cadenced \(cadences.count) times")
            if let cadence = cadences.first {
                cadenced.insert(name)
                #expect(cadence.frameIndex > 0, "\(name) cadenced before it folded")
                #expect(cadence.degree == tonic)
                let after = score.drop { $0.frameIndex < cadence.frameIndex }
                #expect(after.allSatisfy { $0.degree == tonic })
            }
        }

        // Measured mean confidence tells us exactly who should resolve. Lysozyme sits at
        // 94.1 to 94.5 from readout 1 onward and myoglobin at 91.8 to 92.3: both plateau.
        for resolved in ["lysozyme", "myoglobin", "ubiquitin", "villin_hp36", "ww_domain"] {
            #expect(cadenced.contains(resolved), "\(resolved) should have resolved")
        }
        // GFP holds at 34 to 37 and alpha-synuclein - an intrinsically disordered protein -
        // at 31 to 39. Both are below the floor, and PLAN.md is explicit that a disordered
        // region must never resolve: it stays a detuned wash for the whole piece.
        for disordered in ["gfp", "alpha_synuclein"] {
            #expect(!cadenced.contains(disordered), "\(disordered) must never resolve")
        }
        // A Genie 2 run's confidence is denoising progress, which climbs monotonically and so
        // never plateaus. A generated backbone has nothing to converge on.
        #expect(!cadenced.contains("genie2_76aa_seed1"))
    }

    @Test("the same trajectory scores identically three times")
    func realTrajectoriesAreDeterministic() async throws {
        let style = try Self.style
        let bundles = try Self.trajectories()
        let chosen = try #require(bundles.first { $0.name == "lysozyme" } ?? bundles.first)
        let frames = try await Self.frames(for: chosen.bundle)
        // PLAN.md's Phase 3 gate, on a real trajectory rather than a constructed one.
        let runs = (0..<3).map { _ in
            Sonifier.score(style: style, residues: chosen.bundle.residues, frames: frames)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }

    // MARK: - A live fold, which is the default path

    @Test("a live fold sounds nearly all of its contacts")
    func liveFoldKeepsItsContacts() async throws {
        let style = try Self.style
        for engine in [FoldingEngine.morph, .structureBased] {
            let steps = engine == .structureBased ? 200_000 : nil
            let (bundle, frames) = try await Self.liveFold("villin_hp36", engine: engine,
                                                           steps: steps)
            let score = Sonifier.score(style: style, residues: bundle.residues, frames: frames)
            try Self.check(score, residues: bundle.residues.count, style: style,
                           name: engine.rawValue)

            let sounded = score.reduce(0) {
                $0 + $1.notes.count { $0.voice == .contact || $0.voice == .bass }
            }
            let dropped = score.reduce(0) { $0 + $1.droppedContacts }
            #expect(sounded > 0, "\(engine.rawValue) sounded no contacts at all")
            // The cap exists to stop a cluster, not to rewrite the fold. On the path the app
            // actually takes it should almost never bite: measured p99 is 13 contacts per
            // readout for villin under the structure-based model, against a cap of 16.
            let fraction = Double(dropped) / Double(sounded + dropped)
            #expect(fraction < 0.05,
                    "\(engine.rawValue) dropped \(dropped) of \(sounded + dropped) contacts")

            // A live fold starts genuinely unfolded and ends compact: the accelerando has
            // somewhere to go.
            let first = try #require(score.first)
            let last = try #require(score.last)
            #expect(last.compaction > first.compaction)
            #expect(last.tempo > first.tempo)
        }
    }

    @Test("a live fold resolves, and only once")
    func liveFoldCadences() async throws {
        let style = try Self.style
        let (bundle, frames) = try await Self.liveFold("villin_hp36", engine: .morph)
        let score = Sonifier.score(style: style, residues: bundle.residues, frames: frames)
        let cadences = score.filter(\.isCadence)
        #expect(cadences.count == 1)
        let cadence = try #require(cadences.first)
        // Late in the piece, not at the start: a morph resolves as it arrives.
        #expect(Double(cadence.frameIndex) > Double(score.count) * 0.5)
    }
}
