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
                                            backbone: backbone, pLDDT: plddt))
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
            #expect(a.pLDDT == b.pLDDT)
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
        #expect(decoded.readouts.last?.pLDDT == original.readouts.last?.pLDDT)
    }

    @Test("header layout is exactly as documented")
    func headerLayout() throws {
        let data = try TrajectoryBundleCodec.encode(Self.fixture(residues: 7, readouts: 5))
        #expect(data.subdata(in: 0..<8) == Data("PFTRAJ01".utf8))
        let version = data.subdata(in: 8..<12).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        #expect(version == 1)
        let metadataLength = Int(data.subdata(in: 12..<16).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        // 16 header + metadata + 8 (residue count, readout count) + body
        #expect(data.count == 16 + metadataLength + 8 + 5 * (8 + 7 * 13 * 4))
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
                                         backbone: good.readouts[0].backbone,
                                         pLDDT: Array(good.readouts[0].pLDDT.dropLast()))])
        #expect(good.isConsistent)
        #expect(bad.isConsistent == false)
    }

    @Test("consistency check catches a non-finite coordinate")
    func consistencyCatchesNaN() {
        let good = Self.fixture(residues: 7, readouts: 2)
        var backbone = good.readouts[0].backbone
        backbone[3].ca.z = .nan
        let bad = TrajectoryBundle(
            metadata: good.metadata,
            readouts: [TrajectoryReadout(recycle: 0, blockIndex: 0, backbone: backbone,
                                         pLDDT: good.readouts[0].pLDDT)])
        #expect(bad.isConsistent == false)
    }
}
