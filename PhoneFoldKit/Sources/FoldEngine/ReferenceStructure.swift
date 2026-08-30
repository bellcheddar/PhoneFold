import Foundation
import simd
import FoldCore

/// A known structure to fold toward: the destination of a simulation or a morph.
///
/// This is what makes "fold *this* protein" possible for a protein that is not in the app's
/// bundle. It is a downloaded answer, not a prediction the app made, and every engine that
/// consumes one carries a disclosure saying so.
public struct ReferenceStructure: Sendable, Hashable {
    public let accession: String
    public let name: String
    /// One-letter sequence, as long as `caPositions`.
    public let sequence: String
    public let caPositions: [SIMD3<Double>]
    /// AlphaFold's per-residue pLDDT, which is the model's confidence in *its own* prediction
    /// of this structure - not a confidence in the fold the app then simulates toward it.
    public let pLDDT: [Float]

    public var residueCount: Int { caPositions.count }

    public init(accession: String, name: String, sequence: String,
                caPositions: [SIMD3<Double>], pLDDT: [Float]) {
        self.accession = accession
        self.name = name
        self.sequence = sequence
        self.caPositions = caPositions
        self.pLDDT = pLDDT
    }

    public var residues: [AminoAcid] { sequence.map { AminoAcid(code: $0) } }
}

/// Reads the alpha-carbon trace out of an mmCIF file.
///
/// **Column positions are read from the loop header, never assumed.** mmCIF is whitespace
/// delimited with a declared column order, and that order is not fixed across producers or
/// versions - AlphaFold's own files went from `model_v4` to `model_v6` during this project, and
/// a parser that counts fields from the left is one release away from silently reading the
/// occupancy as a coordinate. Fixed-width slicing is worse still: it drops every `ATOM` line
/// while `HETATM` happens to line up, which looks like a protein with no backbone.
public enum MMCIFParser {

    public enum Failure: Error, CustomStringConvertible {
        case noAtomSiteLoop
        case missingColumn(String)
        case noAlphaCarbons

        public var description: String {
            switch self {
            case .noAtomSiteLoop: "This file has no atom_site loop."
            case .missingColumn(let name): "The atom_site loop has no \(name) column."
            case .noAlphaCarbons: "This file has no alpha carbons."
            }
        }
    }

    public struct Residue: Sendable, Hashable {
        public let name: String
        public let sequenceNumber: Int
        public let position: SIMD3<Double>
        /// The B-factor column, which for an AlphaFold model carries pLDDT.
        public let bFactor: Float
    }

    /// Every alpha carbon in the first model of the file, in sequence order.
    public static func alphaCarbons(_ text: String) throws -> [Residue] {
        var columns: [String: Int] = [:]
        var order = 0
        var residues: [Residue] = []
        var seen = Set<Int>()
        var inLoop = false

        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("_atom_site.") {
                let key = String(line.dropFirst("_atom_site.".count))
                    .trimmingCharacters(in: .whitespaces)
                columns[key] = order
                order += 1
                inLoop = true
                continue
            }
            guard inLoop else { continue }
            guard line.hasPrefix("ATOM") || line.hasPrefix("HETATM") else {
                // The loop ends at the next block; anything else before an ATOM is header.
                if line.hasPrefix("#") || line.hasPrefix("loop_") || line.hasPrefix("_") {
                    continue
                }
                if !residues.isEmpty { break }
                continue
            }
            guard let atomColumn = columns["label_atom_id"],
                  let compColumn = columns["label_comp_id"],
                  let xColumn = columns["Cartn_x"],
                  let yColumn = columns["Cartn_y"],
                  let zColumn = columns["Cartn_z"]
            else { throw Failure.missingColumn("label_atom_id/label_comp_id/Cartn_x/y/z") }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > Swift.max(zColumn, compColumn) else { continue }
            guard fields[atomColumn] == "CA" else { continue }

            // Only the first model: a multi-model file would otherwise stack copies of the
            // same chain on top of each other.
            if let modelColumn = columns["pdbx_PDB_model_num"], fields.count > modelColumn,
               fields[modelColumn] != "1" { continue }

            let sequenceNumber = columns["label_seq_id"].flatMap { index -> Int? in
                fields.count > index ? Int(fields[index]) : nil
            } ?? residues.count + 1
            // A residue can appear twice with alternate locations; keep the first.
            guard !seen.contains(sequenceNumber) else { continue }
            seen.insert(sequenceNumber)

            guard let x = Double(fields[xColumn]), let y = Double(fields[yColumn]),
                  let z = Double(fields[zColumn]) else { continue }
            let b = columns["B_iso_or_equiv"].flatMap { index -> Float? in
                fields.count > index ? Float(fields[index]) : nil
            } ?? 0

            residues.append(Residue(name: String(fields[compColumn]),
                                    sequenceNumber: sequenceNumber,
                                    position: SIMD3<Double>(x, y, z),
                                    bFactor: b))
        }
        guard !columns.isEmpty else { throw Failure.noAtomSiteLoop }
        guard !residues.isEmpty else { throw Failure.noAlphaCarbons }
        return residues.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    /// Three-letter residue names to one-letter codes.
    public static func oneLetter(_ threeLetter: String) -> Character {
        AminoAcid.allCases.first { $0.threeLetterCode == threeLetter.uppercased() }?.code ?? "X"
    }
}

/// Fetches a reference structure from the AlphaFold Protein Structure Database.
///
/// **The file URL is asked for, not constructed.** AlphaFold's filenames carry a version, and
/// building `AF-{accession}-F1-model_v4.cif` by hand returns 404 today - the current release is
/// v6, and it moved during this project. The prediction API reports the URL for whatever the
/// latest version is, along with the sequence, so one request removes a whole class of
/// breakage that would otherwise surface as "that protein does not exist".
public struct AlphaFoldClient: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case notFound(accession: String)
        case transport(String)
        case malformedResponse

        public var description: String {
            switch self {
            case .notFound(let a): "AlphaFold has no prediction for \(a)."
            case .transport(let m): "Could not reach AlphaFold: \(m)"
            case .malformedResponse: "AlphaFold returned something unreadable."
            }
        }
    }

    private struct Prediction: Decodable {
        let uniprotAccession: String
        let uniprotDescription: String?
        let sequence: String
        let cifUrl: String
    }

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func reference(for accession: String) async throws -> ReferenceStructure {
        let trimmed = accession.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let apiURL = URL(string:
            "https://alphafold.ebi.ac.uk/api/prediction/\(trimmed)") else {
            throw Failure.notFound(accession: trimmed)
        }
        let (data, response) = try await session.data(from: apiURL)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw Failure.notFound(accession: trimmed)
        }
        guard let predictions = try? JSONDecoder().decode([Prediction].self, from: data),
              let prediction = predictions.first,
              let cifURL = URL(string: prediction.cifUrl)
        else { throw Failure.malformedResponse }

        let (cif, _) = try await session.data(from: cifURL)
        guard let text = String(data: cif, encoding: .utf8) else {
            throw Failure.malformedResponse
        }
        let residues = try MMCIFParser.alphaCarbons(text)
        return ReferenceStructure(
            accession: prediction.uniprotAccession,
            name: prediction.uniprotDescription ?? prediction.uniprotAccession,
            // The structure's own residues, not the API's sequence field: a prediction can
            // cover a fragment of a long entry, and a sequence longer than the coordinates
            // would misalign every residue type in the app.
            sequence: String(residues.map { MMCIFParser.oneLetter($0.name) }),
            caPositions: residues.map(\.position),
            pLDDT: residues.map(\.bFactor))
    }
}
