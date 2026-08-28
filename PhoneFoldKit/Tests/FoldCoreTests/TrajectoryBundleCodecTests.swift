import Testing
import Foundation
import simd
@testable import FoldCore

@Suite("TrajectoryBundleCodec")
struct TrajectoryBundleCodecTests {

    /// A small, fully specified bundle with coordinates that are awkward on purpose:
    /// negative, fractional, and not aligned to anything.
    static func fixture(residues: Int = 7, readouts: Int = 5) -> TrajectoryBundle {
        let metadata = TrajectoryMetadata(
            name: "Codec fixture",
            sequence: String("MKVFGRCELA".prefix(residues)).padding(
                toLength: residues, withPad: "G", startingAt: 0),
            accession: "P00698",
            organism: "Gallus gallus",
            listeningNote: "not shipped: a codec fixture",
            referencePDBID: "1UBQ",
            provenance: .testFixture,
            sourceModel: "none/test-fixture",
            blocksPerReadout: 4,
            recycles: 2,
            generated: "2026-08-28T00:00:00Z",
            notes: "deterministic geometric construction, never presented as a fold")

        var frames: [TrajectoryReadout] = []
        for f in 0..<readouts {
            var backbone: [BackboneResidue] = []
            for k in 0..<residues {
                let base = SIMD3<Float>(Float(k) * 3.8 - 11.25,
                                        Float(f) * -0.37,
                                        sin(Float(k) * 0.7) * 4.125)
                backbone.append(BackboneResidue(
                    n: base + SIMD3<Float>(-0.5, 0.125, -0.625),
                    ca: base,
                    c: base + SIMD3<Float>(0.5, -0.125, 0.625),
                    o: base + SIMD3<Float>(0.875, 0.5, 0.75)))
            }
            let plddt = (0..<residues).map { Float($0) * 1.5 + Float(f) * 3.25 }
            frames.append(TrajectoryReadout(recycle: f / 3, blockIndex: f * 4,
                                            backbone: backbone, confidence: plddt))
        }
        return TrajectoryBundle(metadata: metadata, readouts: frames)
    }

    @Test("round-trips exactly, bit for bit")
    func roundTrip() throws {
        let original = Self.fixture()
        let decoded = try TrajectoryBundleCodec.decode(TrajectoryBundleCodec.encode(original))

        #expect(decoded.metadata == original.metadata)
        #expect(decoded.readouts.count == original.readouts.count)
        for (a, b) in zip(decoded.readouts, original.readouts) {
            #expect(a.recycle == b.recycle)
            #expect(a.blockIndex == b.blockIndex)
            // float32 in, float32 out: exact equality is the correct assertion here.
            #expect(a.backbone == b.backbone)
            #expect(a.confidence == b.confidence)
        }
        #expect(decoded.isConsistent)
    }

    @Test("encoding is deterministic, so a bundle can be hashed for the manifest")
    func deterministicEncoding() throws {
        let b = Self.fixture()
        #expect(try TrajectoryBundleCodec.encode(b) == TrajectoryBundleCodec.encode(b))
    }

    @Test("round-trips through a file on disk")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-codec-\(UUID().uuidString).pftraj")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = Self.fixture(residues: 40, readouts: 12)
        try TrajectoryBundleCodec.write(original, to: url)
        let decoded = try TrajectoryBundleCodec.read(contentsOf: url)

        #expect(decoded.metadata.sequence == original.metadata.sequence)
        #expect(decoded.readouts.last?.confidence == original.readouts.last?.confidence)
    }

    @Test("header layout is exactly as documented")
    func headerLayout() throws {
        let data = try TrajectoryBundleCodec.encode(Self.fixture(residues: 7, readouts: 5))
        #expect(data.subdata(in: 0..<8) == Data("PFTRAJ01".utf8))
        let version = data.subdata(in: 8..<12).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        #expect(version == 2)
        let metadataLength = Int(data.subdata(in: 12..<16).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        // 16 header + metadata + 12 (residue count, readout count, atoms) + body
        #expect(data.count == 16 + metadataLength + 12 + 5 * (8 + 7 * 13 * 4))
    }

    // A reader that has only ever been handed its own output is not a reader. Each of these
    // is a way a real file goes wrong: wrong file entirely, a newer writer, a half-written
    // file, and a metadata block that disagrees with the body.

    @Test("a file that is not a trajectory is rejected by name")
    func rejectsForeignFile() {
        let notATrajectory = Data("PK\u{03}\u{04}some zip file".utf8)
        #expect(throws: TrajectoryBundleCodec.CodecError.notATrajectoryFile) {
            try TrajectoryBundleCodec.decode(notATrajectory)
        }
    }

    @Test("a future format version is refused rather than misread")
    func rejectsFutureVersion() throws {
        var data = try TrajectoryBundleCodec.encode(Self.fixture())
        data.replaceSubrange(8..<12, with: Swift.withUnsafeBytes(of: UInt32(99).littleEndian) {
            Data($0)
        })
        #expect(throws: TrajectoryBundleCodec.CodecError.unsupportedVersion(99)) {
            try TrajectoryBundleCodec.decode(data)
        }
    }

    @Test("truncation is caught before allocating a trajectory", arguments: [4, 20, 200])
    func rejectsTruncation(keep: Int) throws {
        let full = try TrajectoryBundleCodec.encode(Self.fixture(residues: 40, readouts: 12))
        let truncated = full.prefix(keep)
        #expect(throws: (any Error).self) {
            try TrajectoryBundleCodec.decode(Data(truncated))
        }
    }

    @Test("a body one byte short is caught, not read as garbage")
    func rejectsOneByteShort() throws {
        let full = try TrajectoryBundleCodec.encode(Self.fixture(residues: 40, readouts: 12))
        #expect(throws: (any Error).self) {
            try TrajectoryBundleCodec.decode(full.dropLast())
        }
    }

    @Test("metadata that disagrees with the body is rejected")
    func rejectsResidueCountMismatch() throws {
        // Encode a 7-residue bundle, then rewrite the metadata to claim 8 residues.
        var b = Self.fixture(residues: 7, readouts: 3)
        b.metadata.sequence += "A"                       // 8 residues in the metadata
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let newJSON = try encoder.encode(b.metadata)

        var data = try TrajectoryBundleCodec.encode(Self.fixture(residues: 7, readouts: 3))
        let oldLength = Int(data.subdata(in: 12..<16).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        data.replaceSubrange(16..<(16 + oldLength), with: newJSON)
        data.replaceSubrange(12..<16, with: Swift.withUnsafeBytes(
            of: UInt32(newJSON.count).littleEndian) { Data($0) })

        #expect(throws: TrajectoryBundleCodec.CodecError.inconsistentResidueCount(
            header: 7, sequence: 8)) {
            try TrajectoryBundleCodec.decode(data)
        }
    }

    @Test("consistency check catches a short per-residue array")
    func consistencyCatchesShortArray() {
        let good = Self.fixture(residues: 7, readouts: 2)
        let bad = TrajectoryBundle(
            metadata: good.metadata,
            readouts: [TrajectoryReadout(recycle: 0, blockIndex: 0,
                                         backbone: good.readouts[0].backbone!,
                                         confidence: Array(good.readouts[0].confidence.dropLast()))])
        #expect(good.isConsistent)
        #expect(bad.isConsistent == false)
    }

    @Test("consistency check catches a non-finite coordinate")
    func consistencyCatchesNaN() {
        let good = Self.fixture(residues: 7, readouts: 2)
        var backbone = good.readouts[0].backbone!
        backbone[3].ca.z = .nan
        let bad = TrajectoryBundle(
            metadata: good.metadata,
            readouts: [TrajectoryReadout(recycle: 0, blockIndex: 0, backbone: backbone,
                                         confidence: good.readouts[0].confidence)])
        #expect(bad.isConsistent == false)
    }
}

/// Genie 2 emits a CA trace and nothing else. Storing constructed N and C atoms to fill a
/// fixed four-atom record would be inventing coordinates and presenting them as model
/// output, so the container carries CA-only frames as a first-class case.
@Suite("CA-trace trajectories")
struct CATraceCodecTests {

    static func caFixture(residues: Int = 12, readouts: Int = 6) -> TrajectoryBundle {
        let metadata = TrajectoryMetadata(
            name: "Generated CA trace",
            sequence: String(repeating: "X", count: residues),
            provenance: .genie2Denoising,
            sourceModel: "aqlaboratory/genie2",
            blocksPerReadout: 5, recycles: 1,
            generated: "2026-08-28T00:00:00Z")
        var frames: [TrajectoryReadout] = []
        for f in 0..<readouts {
            let ca = (0..<residues).map { k in
                SIMD3<Float>(Float(k) * 3.75 - 11.25, Float(f) * -0.5, Float(k) * 0.25)
            }
            frames.append(TrajectoryReadout(
                recycle: 0, blockIndex: f * 5, caPositions: ca,
                confidence: (0..<residues).map { _ in Float(f) * 20 }))
        }
        return TrajectoryBundle(metadata: metadata, readouts: frames)
    }

    @Test("a CA-trace bundle round-trips and reports no full backbone")
    func caRoundTrip() throws {
        let original = Self.caFixture()
        let decoded = try TrajectoryBundleCodec.decode(TrajectoryBundleCodec.encode(original))

        #expect(decoded.hasFullBackbone == false)
        #expect(decoded.isConsistent)
        #expect(decoded.readouts.count == original.readouts.count)
        for (a, b) in zip(decoded.readouts, original.readouts) {
            #expect(a.backbone == nil)
            #expect(a.caPositions == b.caPositions)
            #expect(a.confidence == b.confidence)
            #expect(a.atomsPerResidue == 1)
        }
    }

    @Test("a CA-trace file is a quarter the size of the equivalent full backbone")
    func caIsSmaller() throws {
        let ca = try TrajectoryBundleCodec.encode(Self.caFixture(residues: 12, readouts: 6))
        // 6 frames * (8 header + 12 residues * (3 coords + 1 confidence) * 4 bytes)
        let expectedBody = 6 * (8 + 12 * (1 * 3 + 1) * 4)
        let fullBody = 6 * (8 + 12 * (4 * 3 + 1) * 4)
        #expect(ca.count < fullBody)
        #expect(ca.count > expectedBody)   // plus header and metadata
    }

    @Test("a full-backbone bundle still reports its backbone")
    func fullBackboneStillWorks() throws {
        let bundle = TrajectoryBundleCodecTests.fixture()
        let decoded = try TrajectoryBundleCodec.decode(TrajectoryBundleCodec.encode(bundle))
        #expect(decoded.hasFullBackbone)
        #expect(decoded.readouts.allSatisfy { $0.atomsPerResidue == 4 })
        // CA is populated from the backbone, so both access paths agree.
        for r in decoded.readouts {
            #expect(r.caPositions == r.backbone!.map(\.ca))
        }
    }

    /// A bundle whose frames disagree about geometry would make the renderer pick a path
    /// once and then be wrong for the rest of the trajectory.
    @Test("a bundle may not mix CA-trace and full-backbone frames")
    func mixedBundleIsRejected() throws {
        let full = TrajectoryBundleCodecTests.fixture(residues: 12, readouts: 2)
        let ca = Self.caFixture(residues: 12, readouts: 2)
        let mixed = TrajectoryBundle(metadata: ca.metadata,
                                     readouts: [ca.readouts[0], full.readouts[0]])
        #expect(mixed.isConsistent == false)
        #expect(throws: TrajectoryBundleCodec.CodecError.inconsistentReadouts) {
            try TrajectoryBundleCodec.encode(mixed)
        }
    }

    /// Version 1 files predate CA traces and always stored four atoms. They must keep
    /// decoding: the twelve ESMFold trajectories on disk are version 1.
    @Test("version 1 files still decode, as a full backbone")
    func version1BackwardCompatibility() throws {
        var data = try TrajectoryBundleCodec.encode(
            TrajectoryBundleCodecTests.fixture(residues: 7, readouts: 3))
        // Rewrite as a version 1 file: stamp the version and drop the atoms-per-residue word.
        let metadataLength = Int(data.subdata(in: 12..<16).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        data.replaceSubrange(8..<12, with: Swift.withUnsafeBytes(of: UInt32(1).littleEndian) {
            Data($0)
        })
        let atomsWordAt = 16 + metadataLength + 8
        data.removeSubrange(atomsWordAt..<(atomsWordAt + 4))

        let decoded = try TrajectoryBundleCodec.decode(data)
        #expect(decoded.hasFullBackbone)
        #expect(decoded.readouts.count == 3)
        #expect(decoded.isConsistent)
    }
}
