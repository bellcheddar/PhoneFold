import Foundation
import simd

/// Reader and writer for the `.pftraj` container.
///
/// Layout, little-endian throughout (every Apple platform PhoneFold targets is
/// little-endian, and the format is not an interchange format for anyone else):
///
/// ```
///   offset  size          field
///   0       8             magic, ASCII "PFTRAJ01"
///   8       4  uint32     format version
///   12      4  uint32     JSON metadata length in bytes, M
///   16      M             TrajectoryMetadata as UTF-8 JSON
///   16+M    4  uint32     residue count, N
///   +4      4  uint32     readout count, F
///   then F records, each:
///           4  uint32     recycle
///           4  uint32     blockIndex
///           N*12 float32  backbone, residue-major, atom order N, CA, C, O, xyz each
///           N    float32  pLDDT
/// ```
///
/// Coordinates are float32 angstroms. There is no compression: these files are a few MB and
/// the app must memory-map and stream them without a decode stall on the audio clock.
public enum TrajectoryBundleCodec {

    public static let magic = "PFTRAJ01"
    public static let currentVersion: UInt32 = 1

    public enum CodecError: Error, CustomStringConvertible, Equatable {
        case notATrajectoryFile
        case unsupportedVersion(UInt32)
        case truncated(expected: Int, got: Int)
        case metadataDecodingFailed(String)
        case inconsistentResidueCount(header: Int, sequence: Int)

        public var description: String {
            switch self {
            case .notATrajectoryFile:
                "not a PhoneFold trajectory: the file does not begin with \(magic)"
            case .unsupportedVersion(let v):
                "trajectory format version \(v) is newer than this build understands (\(currentVersion))"
            case .truncated(let expected, let got):
                "trajectory file is truncated: expected at least \(expected) bytes, got \(got)"
            case .metadataDecodingFailed(let why):
                "trajectory metadata could not be decoded: \(why)"
            case .inconsistentResidueCount(let header, let sequence):
                "trajectory header says \(header) residues but the sequence has \(sequence)"
            }
        }
    }

    // MARK: - Writing

    public static func encode(_ bundle: TrajectoryBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic bytes for hashing
        let metadataJSON = try encoder.encode(bundle.metadata)

        let n = bundle.metadata.residueCount
        var data = Data()
        data.reserveCapacity(16 + metadataJSON.count + 8
                             + bundle.readouts.count * (8 + n * 13 * 4))

        data.append(contentsOf: Array(magic.utf8))
        data.appendLE(currentVersion)
        data.appendLE(UInt32(metadataJSON.count))
        data.append(metadataJSON)
        data.appendLE(UInt32(n))
        data.appendLE(UInt32(bundle.readouts.count))

        for r in bundle.readouts {
            data.appendLE(UInt32(r.recycle))
            data.appendLE(UInt32(r.blockIndex))
            for res in r.backbone {
                for v in [res.n, res.ca, res.c, res.o] {
                    data.appendLE(v.x); data.appendLE(v.y); data.appendLE(v.z)
                }
            }
            for p in r.pLDDT { data.appendLE(p) }
        }
        return data
    }

    // MARK: - Reading

    public static func decode(_ data: Data) throws -> TrajectoryBundle {
        var cursor = 0

        func need(_ count: Int) throws {
            guard data.count >= cursor + count else {
                throw CodecError.truncated(expected: cursor + count, got: data.count)
            }
        }

        try need(16)
        guard data.subdata(in: 0..<8) == Data(magic.utf8) else {
            throw CodecError.notATrajectoryFile
        }
        cursor = 8

        let version: UInt32 = data.loadLE(at: &cursor)
        guard version <= currentVersion else { throw CodecError.unsupportedVersion(version) }

        let metadataLength = Int(data.loadLE(at: &cursor) as UInt32)
        try need(metadataLength)
        let metadataJSON = data.subdata(in: cursor..<(cursor + metadataLength))
        cursor += metadataLength

        let metadata: TrajectoryMetadata
        do {
            metadata = try JSONDecoder().decode(TrajectoryMetadata.self, from: metadataJSON)
        } catch {
            throw CodecError.metadataDecodingFailed(String(describing: error))
        }

        try need(8)
        let n = Int(data.loadLE(at: &cursor) as UInt32)
        let frameCount = Int(data.loadLE(at: &cursor) as UInt32)

        guard n == metadata.residueCount else {
            throw CodecError.inconsistentResidueCount(header: n, sequence: metadata.residueCount)
        }

        // Check the whole body length once rather than per-field: a truncated file should
        // fail immediately, not after allocating most of a trajectory.
        let bodyBytes = frameCount * (8 + n * 13 * 4)
        try need(bodyBytes)

        var readouts: [TrajectoryReadout] = []
        readouts.reserveCapacity(frameCount)

        for _ in 0..<frameCount {
            let recycle = Int(data.loadLE(at: &cursor) as UInt32)
            let blockIndex = Int(data.loadLE(at: &cursor) as UInt32)

            var backbone: [BackboneResidue] = []
            backbone.reserveCapacity(n)
            for _ in 0..<n {
                var atoms: [SIMD3<Float>] = []
                atoms.reserveCapacity(4)
                for _ in 0..<4 {
                    let x: Float = data.loadLE(at: &cursor)
                    let y: Float = data.loadLE(at: &cursor)
                    let z: Float = data.loadLE(at: &cursor)
                    atoms.append(SIMD3<Float>(x, y, z))
                }
                backbone.append(BackboneResidue(n: atoms[0], ca: atoms[1],
                                                c: atoms[2], o: atoms[3]))
            }

            var pLDDT: [Float] = []
            pLDDT.reserveCapacity(n)
            for _ in 0..<n { pLDDT.append(data.loadLE(at: &cursor)) }

            readouts.append(TrajectoryReadout(recycle: recycle, blockIndex: blockIndex,
                                              backbone: backbone, pLDDT: pLDDT))
        }

        return TrajectoryBundle(metadata: metadata, readouts: readouts)
    }

    public static func read(contentsOf url: URL) throws -> TrajectoryBundle {
        try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func write(_ bundle: TrajectoryBundle, to url: URL) throws {
        try encode(bundle).write(to: url, options: .atomic)
    }
}

// MARK: - Little-endian primitives

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Float) {
        Swift.withUnsafeBytes(of: value.bitPattern.littleEndian) { append(contentsOf: $0) }
    }

    /// Reads a little-endian `UInt32` and advances the cursor. Uses `loadUnaligned` because
    /// the JSON metadata block gives the body an arbitrary alignment.
    func loadLE(at cursor: inout Int) -> UInt32 {
        let raw = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
        cursor += 4
        return UInt32(littleEndian: raw)
    }

    func loadLE(at cursor: inout Int) -> Float {
        let bits: UInt32 = loadLE(at: &cursor)
        return Float(bitPattern: bits)
    }
}
