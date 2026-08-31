import Foundation
import simd

/// A structure read from a file someone dropped on the app.
///
/// PLAN.md Phase 5a: "Drag and drop of PDB and mmCIF files to compare a prediction against an
/// experimental structure (superpose, show RMSD per residue) - the one analytical concession,
/// because on a Mac it is expected."
///
/// Only what a comparison needs: alpha carbons, their residue numbers, and their chain. Not a
/// general structure library, and it should not become one - PLAN is explicit that anything
/// further analytical belongs in another project.
public struct StructureFile: Sendable, Equatable {

    public struct Residue: Sendable, Equatable {
        /// The author's residue number, which is what a person reads off a paper and what two
        /// files of the same protein have in common. Not the index in the array.
        public let number: Int
        public let name: String
        public let chain: String
        public let ca: SIMD3<Float>
        /// B-factor in an experimental file, pLDDT in a predicted one. The column is the same
        /// and the meaning is not, which is why this is not called `confidence`.
        public let bFactor: Float

        public init(number: Int, name: String, chain: String, ca: SIMD3<Float>,
                    bFactor: Float) {
            self.number = number
            self.name = name
            self.chain = chain
            self.ca = ca
            self.bFactor = bFactor
        }
    }

    public var identifier: String
    public var residues: [Residue]

    public var chains: [String] { Array(Set(residues.map(\.chain))).sorted() }

    public func residues(inChain chain: String) -> [Residue] {
        residues.filter { $0.chain == chain }
    }

    public init(identifier: String, residues: [Residue]) {
        self.identifier = identifier
        self.residues = residues
    }

    public enum Failure: Error, CustomStringConvertible {
        case unrecognisedFormat
        case noAlphaCarbons(String)

        public var description: String {
            switch self {
            case .unrecognisedFormat:
                "That file is neither PDB nor mmCIF as far as this can tell."
            case .noAlphaCarbons(let what):
                "\(what) has no alpha carbons to compare. A nucleic acid or a ligand-only file "
                    + "will do this."
            }
        }
    }

    // MARK: - Reading

    /// Read either format, deciding which by looking at the content.
    ///
    /// By content rather than by extension, because a file dragged out of a colleague's email
    /// is called whatever they called it, and `.txt` holding a PDB is common.
    public static func read(_ text: String, identifier: String = "") throws -> StructureFile {
        let looksLikeCIF = text.contains("_atom_site.") || text.hasPrefix("data_")
        let structure = looksLikeCIF
            ? try readMMCIF(text, identifier: identifier)
            : try readPDB(text, identifier: identifier)
        guard !structure.residues.isEmpty else {
            throw Failure.noAlphaCarbons(structure.identifier.isEmpty
                                         ? "that file" : structure.identifier)
        }
        return structure
    }

    /// The legacy PDB format: **fixed columns, and they matter.**
    ///
    /// This is the opposite rule from mmCIF, where fields are whitespace-separated and slicing
    /// by column silently drops records. Getting the two the wrong way round is a documented
    /// way to lose every atom in a file while the parse appears to succeed.
    ///
    /// The subtle one is the atom name in columns 13 to 16. The element symbol is right
    /// justified in 13 and 14, so an alpha carbon is `" CA "` and a calcium ion is `"CA  "`.
    /// Trimming both gives `"CA"` and quietly turns every calcium in the file into a residue.
    /// The comparison is therefore against the four characters, not the trimmed name.
    static func readPDB(_ text: String, identifier: String) throws -> StructureFile {
        var residues: [Residue] = []
        var entry = identifier
        var seen: Set<String> = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(line)
            if entry.isEmpty, line.hasPrefix("HEADER"), characters.count >= 66 {
                entry = String(characters[62..<66]).trimmingCharacters(in: .whitespaces)
            }
            // The first model only. An NMR ensemble has dozens and comparing against "the
            // structure" means the first one, not a superposition of all of them.
            if line.hasPrefix("ENDMDL") { break }
            guard line.hasPrefix("ATOM"), characters.count >= 54 else { continue }

            let atomName = String(characters[12..<16])
            guard atomName == " CA " else { continue }

            // Alternate locations: take the first, which is blank or A. Taking all of them
            // gives two residue 30s and a comparison that is off by one from there on.
            let altLoc = characters[16]
            guard altLoc == " " || altLoc == "A" else { continue }

            let name = String(characters[17..<20]).trimmingCharacters(in: .whitespaces)
            let chain = String(characters[21]).trimmingCharacters(in: .whitespaces)
            guard let number = Int(String(characters[22..<26])
                .trimmingCharacters(in: .whitespaces)) else { continue }
            guard let x = Float(String(characters[30..<38]).trimmingCharacters(in: .whitespaces)),
                  let y = Float(String(characters[38..<46]).trimmingCharacters(in: .whitespaces)),
                  let z = Float(String(characters[46..<54]).trimmingCharacters(in: .whitespaces))
            else { continue }
            let b = characters.count >= 66
                ? Float(String(characters[60..<66]).trimmingCharacters(in: .whitespaces)) ?? 0
                : 0

            // An insertion code makes two residues share a number; keep them distinct by
            // chain and code so neither is silently dropped.
            let key = "\(chain)|\(number)|\(characters.count > 26 ? characters[26] : " ")"
            guard seen.insert(key).inserted else { continue }
            residues.append(Residue(number: number, name: name, chain: chain,
                                    ca: SIMD3(x, y, z), bFactor: b))
        }
        return StructureFile(identifier: entry, residues: residues)
    }

    /// mmCIF, via the reader the exports are already checked against.
    ///
    /// **Whitespace-separated, never sliced by column.** `line[0..<6]` matches `HETATM` by luck
    /// and drops every `ATOM`, which looks like a file with no protein in it.
    static func readMMCIF(_ text: String, identifier: String) throws -> StructureFile {
        var columns: [String: Int] = [:]
        var order: [String] = []
        var inHeader = false
        var residues: [Residue] = []
        var seen: Set<String> = []
        var entry = identifier
        var stoppedAtSecondModel = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty, line.hasPrefix("data_") {
                entry = String(line.dropFirst(5))
            }
            if line.hasPrefix("_atom_site.") {
                let key = String(line.dropFirst("_atom_site.".count))
                    .split(separator: " ").first.map(String.init) ?? ""
                columns[key] = order.count
                order.append(key)
                inHeader = true
                continue
            }
            guard !columns.isEmpty else { continue }
            guard line.hasPrefix("ATOM") else {
                // The loop ends at the first line that is not an atom record, once started.
                if inHeader, !line.isEmpty, !line.hasPrefix("HETATM"), !residues.isEmpty {
                    break
                }
                continue
            }
            inHeader = false

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            func field(_ name: String) -> String? {
                guard let index = columns[name], index < fields.count else { return nil }
                return fields[index]
            }
            guard field("label_atom_id") == "CA" else { continue }
            let alt = field("label_alt_id") ?? "."
            guard alt == "." || alt == "A" else { continue }

            // Only the first model, as with an NMR ensemble in PDB format.
            if let model = field("pdbx_PDB_model_num"), let number = Int(model), number > 1 {
                stoppedAtSecondModel = true
                break
            }

            let name = field("label_comp_id") ?? ""
            let chain = field("auth_asym_id") ?? field("label_asym_id") ?? "A"
            // The **author's** numbering, which is what matches another file of the same
            // protein. `label_seq_id` restarts per entity and is not what a paper cites.
            guard let numberText = field("auth_seq_id") ?? field("label_seq_id"),
                  let number = Int(numberText) else { continue }
            guard let x = field("Cartn_x").flatMap(Float.init),
                  let y = field("Cartn_y").flatMap(Float.init),
                  let z = field("Cartn_z").flatMap(Float.init) else { continue }
            let b = field("B_iso_or_equiv").flatMap(Float.init) ?? 0

            let key = "\(chain)|\(number)"
            guard seen.insert(key).inserted else { continue }
            residues.append(Residue(number: number, name: name, chain: chain,
                                    ca: SIMD3(x, y, z), bFactor: b))
        }
        _ = stoppedAtSecondModel
        return StructureFile(identifier: entry, residues: residues)
    }
}
