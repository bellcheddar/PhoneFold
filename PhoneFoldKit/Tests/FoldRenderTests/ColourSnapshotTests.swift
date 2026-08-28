import Testing
import Foundation
import simd
import FoldCore
import FoldGeometry
@testable import FoldRender

/// Phase 2 gate: "snapshot tests of all four colour modes against reference images".
///
/// The snapshot here is the **colour buffer**, not a rendered image. There is no headless GPU
/// render path in this test target, and a screenshot comparison would test RealityKit's
/// rasteriser rather than PhoneFold's colouring. What can regress in this project is the
/// colour a residue is assigned, and that is exactly what this pins: for a fixed frame of a
/// real trajectory, every mode's per-vertex colours are compared against a stored reference.
///
/// The reference is regenerated with `PHONEFOLD_RECORD_SNAPSHOTS=1`, which is the only way to
/// change it: a snapshot that rewrites itself on mismatch is not a test.
@Suite("Colour mode snapshots")
struct ColourSnapshotTests {

    static let referenceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/colour_snapshots.json")

    /// A fixed, real frame: the last readout of bundled ubiquitin.
    static func fixture() throws -> (packed: [RenderVertex], options: ColourOptions,
                                     confidence: [Float], mesh: TubeMesh) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let readout = try #require(bundle.readouts.last)
        let ss = LearnedSSE.bundled?.assign(caPositions: readout.caPositions)
            ?? PSEA.assign(caPositions: readout.caPositions)
        var profile = TubeGeometry.Profile()
        // Coarse on purpose: the snapshot should be sensitive to colour, not to a change in
        // tessellation density.
        profile.samplesPerResidue = 2
        profile.radialSegments = 6
        let mesh = TubeGeometry.build(caPositions: readout.caPositions,
                                      secondaryStructure: ss, profile: profile)
        let options = ColourOptions(residueCount: bundle.metadata.residueCount,
                                    residues: bundle.residues)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: readout.confidence,
                                         mode: .confidence, options: options)
        return (packed, options, readout.confidence, mesh)
    }

    /// A compact, comparable digest of one mode's colours: every 16th vertex, to three
    /// decimals. Storing every vertex would make a 4 MB fixture that no one can read.
    static func digest(mode: ColourMode) throws -> [String] {
        let (packed, options, _, _) = try fixture()
        return stride(from: 0, to: packed.count, by: 16).map { index in
            let colour = Colouring.colour(packed[index], mode: mode, options: options)
            return String(format: "%.3f,%.3f,%.3f", colour.x, colour.y, colour.z)
        }
    }

    @Test("all four colour modes match their stored snapshot")
    func snapshots() throws {
        var current: [String: [String]] = [:]
        for mode in ColourMode.allCases {
            current[mode.rawValue] = try Self.digest(mode: mode)
        }

        if ProcessInfo.processInfo.environment["PHONEFOLD_RECORD_SNAPSHOTS"] == "1" {
            let data = try JSONEncoder().encode(current)
            try data.write(to: Self.referenceURL)
            print("recorded colour snapshots to \(Self.referenceURL.lastPathComponent)")
            return
        }

        let url = try #require(Bundle.module.url(forResource: "Fixtures/colour_snapshots",
                                                 withExtension: "json"),
                               "no snapshot reference; record with PHONEFOLD_RECORD_SNAPSHOTS=1")
        let reference = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data(contentsOf: url))

        #expect(Set(reference.keys) == Set(ColourMode.allCases.map(\.rawValue)),
                "the reference does not cover every mode")

        for mode in ColourMode.allCases {
            let expected = try #require(reference[mode.rawValue])
            let actual = try #require(current[mode.rawValue])
            #expect(actual.count == expected.count,
                    "\(mode.rawValue): vertex count changed, \(actual.count) vs \(expected.count)")
            var mismatches = 0
            for (a, b) in zip(actual, expected) where a != b { mismatches += 1 }
            #expect(mismatches == 0,
                    "\(mode.rawValue): \(mismatches) of \(expected.count) colours changed")
        }
    }

    /// A snapshot that cannot tell the modes apart would pass while the colouring was broken.
    @Test("the four modes actually differ from each other")
    func modesAreDistinct() throws {
        var digests: [ColourMode: [String]] = [:]
        for mode in ColourMode.allCases { digests[mode] = try Self.digest(mode: mode) }
        let modes = ColourMode.allCases
        for i in 0..<modes.count {
            for j in (i + 1)..<modes.count {
                #expect(digests[modes[i]] != digests[modes[j]],
                        "\(modes[i].rawValue) and \(modes[j].rawValue) produce identical colours")
            }
        }
    }

    /// The snapshot must be stable run to run, or it is noise rather than a reference.
    @Test("digests are deterministic")
    func deterministic() throws {
        for mode in ColourMode.allCases {
            #expect(try Self.digest(mode: mode) == (try Self.digest(mode: mode)))
        }
    }
}
