import Foundation
import simd

/// Writes a fold as mmCIF: the final model, or the whole trajectory as models 1..n.
///
/// PLAN.md Phase 4 asks for both, with pLDDT in the B-factor column, and for the multi-model
/// file to open in PyMOL. mmCIF rather than PDB because the format has no 99,999-atom or
/// four-character-chain limits to run into, and because it is what everything downstream of a
/// structure prediction now speaks.
///
/// **What is written is what was computed, and no more.** A CA-trace provider has no real N, C
/// or O - `FoldFrame` fills them with the alpha carbon's own position - so writing four atoms
/// per residue from one would be inventing three of them. The provenance decides, and a
/// trace-only fold writes CA only and says so in the file.
public enum MMCIFExport {

    /// What the confidence column means, which is not the same thing for every engine.
    public struct Header: Sendable {
        public var entryID: String
        public var title: String
        public var sequence: String?
        public var confidenceSource: ConfidenceSource
        /// The trajectory's own claim about what it is. Written into the file, because a
        /// structure that leaves the app without its provenance is a structure someone will
        /// later mistake for a prediction.
        public var disclosure: String?

        public init(entryID: String, title: String, sequence: String? = nil,
                    confidenceSource: ConfidenceSource = .pLDDT, disclosure: String? = nil) {
            // A data block name may not contain whitespace, and mmCIF readers differ on what
            // they do with one that does: some truncate, some refuse the file.
            self.entryID = entryID.split(whereSeparator: \.isWhitespace).joined(separator: "_")
            self.title = title
            self.sequence = sequence
            self.confidenceSource = confidenceSource
            self.disclosure = disclosure
        }
    }

    /// Backbone atoms, in the order a viewer expects them within a residue.
    static let backboneOrder = ["N", "CA", "C", "O"]

    /// The atom_site columns this writer emits.
    ///
    /// **Longer than the minimum, because the minimum is not enough for a real reader.**
    /// Biotite refuses a file with no `pdbx_PDB_ins_code` - `KeyError` inside
    /// `_fill_annotations` - and it is not alone in assuming the author columns are present.
    /// A file only this module's own parser can read would satisfy nothing.
    ///
    /// Counted, not remembered: the first value here said 20 because five columns were added
    /// and four were counted. The file was correct - Biotite read it - and the constant was
    /// not, which is exactly the direction a test should catch it from.
    static let atomSiteColumns = 21

    /// mmCIF quoting: a value that is empty, or contains a space or a quote, has to be
    /// protected or the column count of the row changes and the file stops parsing.
    static func quoted(_ value: String) -> String {
        if value.isEmpty { return "?" }
        if value.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) || value.contains("'") {
            // A semicolon-delimited text field, which is the only form with no escaping rules
            // to get wrong. It must begin in column one of its own line.
            return "\n;\(value)\n;\n"
        }
        return value
    }

    /// A sequence folded at a fixed width.
    ///
    /// Separate from `folded`, which breaks on spaces: a one-letter sequence has no spaces, so
    /// word-folding leaves a 400-residue protein as one 400-character line - which is a file
    /// some readers truncate rather than reject.
    static func foldedFixed(_ text: String, width: Int = 78) -> String {
        guard width > 0, text.count > width else { return text }
        var lines: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: width, limitedBy: text.endIndex)
                ?? text.endIndex
            lines.append(String(text[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n")
    }

    /// One line of a text field, folded so no line runs past the 80 columns some readers
    /// still assume.
    static func folded(_ text: String, width: Int = 78) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Writing

    /// A whole trajectory, or a single frame, as one mmCIF file.
    ///
    /// Every frame becomes a `pdbx_PDB_model_num`, which is how PyMOL and ChimeraX read a
    /// trajectory: `load file.cif` gives one object with n states.
    public static func write(frames: [FoldFrame], residues: [AminoAcid], header: Header,
                             backboneOnly: Bool = false) -> String {
        var out = "data_\(header.entryID.isEmpty ? "PHONEFOLD" : header.entryID)\n#\n"
        out += "_entry.id   \(header.entryID.isEmpty ? "PHONEFOLD" : header.entryID)\n#\n"
        out += "_struct.title   \(quoted(header.title))\n#\n"

        // What the B-factor column actually holds. Written as a comment *and* as an audit
        // record, because a reader that assumes B-factors are pLDDT will be wrong for three of
        // the four engines, and a number with the wrong name is worse than no number.
        out += "loop_\n_pdbx_audit_conform.name\n_pdbx_audit_conform.value\n"
        out += "B_iso_meaning   \(quoted(header.confidenceSource.displayName))\n"
        out += "generated_by    PhoneFold\n"
        if let disclosure = header.disclosure {
            out += "provenance      \(quoted(folded(disclosure)))\n"
        }
        out += "#\n"

        if let sequence = header.sequence, !sequence.isEmpty {
            out += "_entity_poly.entity_id          1\n"
            out += "_entity_poly.type               polypeptide(L)\n"
            out += "_entity_poly.pdbx_seq_one_letter_code\n;\(foldedFixed(sequence))\n;\n#\n"
        }

        out += """
        loop_
        _atom_site.group_PDB
        _atom_site.id
        _atom_site.type_symbol
        _atom_site.label_alt_id
        _atom_site.label_atom_id
        _atom_site.label_comp_id
        _atom_site.label_asym_id
        _atom_site.label_entity_id
        _atom_site.label_seq_id
        _atom_site.pdbx_PDB_ins_code
        _atom_site.Cartn_x
        _atom_site.Cartn_y
        _atom_site.Cartn_z
        _atom_site.occupancy
        _atom_site.B_iso_or_equiv
        _atom_site.auth_seq_id
        _atom_site.auth_comp_id
        _atom_site.auth_asym_id
        _atom_site.auth_atom_id
        _atom_site.pdbx_formal_charge
        _atom_site.pdbx_PDB_model_num

        """

        var serial = 1
        for (model, frame) in frames.enumerated() {
            for (index, residue) in frame.backbone.enumerated() {
                let acid = index < residues.count ? residues[index] : .unknown
                let confidence = index < frame.pLDDT.count ? frame.pLDDT[index] : 0
                let atoms = backboneOnly ? [("CA", residue.ca)] : residue.atoms
                for (name, position) in atoms {
                    // The element is the first character of the atom name for every backbone
                    // atom; this writer emits no atom for which that is untrue.
                    let element = String(name.prefix(1))
                    // `.` is "inapplicable" and `?` is "unknown"; both are required as
                    // placeholders rather than omitted, because a reader finds its columns by
                    // position within the row.
                    out += String(
                        format: "ATOM %d %@ . %@ %@ A 1 %d ? %.3f %.3f %.3f 1.00 %.2f %d %@ A %@ ? %d\n",
                        serial, element, name, acid.threeLetterCode, index + 1,
                        Double(position.x), Double(position.y), Double(position.z),
                        Double(confidence), index + 1, acid.threeLetterCode, name, model + 1)
                    serial += 1
                }
            }
        }
        out += "#\n"
        return out
    }

    /// The final model only, which is what "export this structure" usually means.
    public static func writeFinal(frame: FoldFrame, residues: [AminoAcid], header: Header,
                                  backboneOnly: Bool = false) -> String {
        write(frames: [frame], residues: residues, header: header, backboneOnly: backboneOnly)
    }

    // MARK: - Reading it back

    /// The parts of an mmCIF this writer produces, read back.
    ///
    /// Enough to prove a round trip and no more: PLAN.md's gate asks that the file parses, and
    /// a reader written to the same column layout as the writer would prove only that the two
    /// agree. This one finds its columns by name from the loop header, which is how a real
    /// mmCIF reader has to work and how a column reordered by mistake would be caught.
    public struct Parsed: Sendable, Equatable {
        public var entryID: String
        public var title: String
        public var modelCount: Int
        public var atomCount: Int
        /// Per model, per atom: name, residue index, position and B-factor.
        public var models: [[(name: String, residue: Int, position: SIMD3<Float>, b: Float)]]

        public static func == (a: Parsed, b: Parsed) -> Bool {
            a.entryID == b.entryID && a.title == b.title
                && a.modelCount == b.modelCount && a.atomCount == b.atomCount
        }
    }

    public enum Malformed: Error, CustomStringConvertible, Equatable {
        case noAtomSite
        case missingColumn(String)
        case shortRow(Int)

        public var description: String {
            switch self {
            case .noAtomSite: "The file has no atom_site loop."
            case .missingColumn(let name): "The atom_site loop has no \(name) column."
            case .shortRow(let line): "Line \(line) has fewer values than the loop has columns."
            }
        }
    }

    public static func parse(_ text: String) throws -> Parsed {
        var entryID = ""
        var title = ""
        var columns: [String: Int] = [:]
        var inLoopHeader = false
        var inAtomSite = false
        var models: [Int: [(name: String, residue: Int, position: SIMD3<Float>, b: Float)]] = [:]
        var atomCount = 0

        var lineNumber = 0
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).makeIterator()
        while let line = lines.next() {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A semicolon text field runs to the next line that is a lone semicolon; nothing
            // inside it is a token, and reading it as one is how a title with a space in it
            // turns into a parse error.
            if trimmed.hasPrefix(";") {
                while let inner = lines.next() {
                    lineNumber += 1
                    if inner.trimmingCharacters(in: .whitespaces) == ";" { break }
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "loop_" {
                inLoopHeader = true
                inAtomSite = false
                columns = [:]
                continue
            }
            if trimmed.hasPrefix("_atom_site.") {
                if inLoopHeader {
                    columns[String(trimmed.dropFirst("_atom_site.".count))] = columns.count
                    inAtomSite = true
                }
                continue
            }
            if trimmed.hasPrefix("_") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.first == "_entry.id", parts.count > 1 { entryID = String(parts[1]) }
                if parts.first == "_struct.title", parts.count > 1 {
                    title = parts.dropFirst().joined(separator: " ")
                }
                if inLoopHeader, !trimmed.hasPrefix("_atom_site.") { inAtomSite = false }
                continue
            }

            guard inAtomSite, !columns.isEmpty else { inLoopHeader = false; continue }
            inLoopHeader = false
            let values = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard values.count >= columns.count else {
                // A data row shorter than the header is the classic mmCIF failure - an
                // unquoted value with a space in it - and it must be a refusal rather than a
                // silently short-read atom.
                throw Malformed.shortRow(lineNumber)
            }
            func value(_ name: String) throws -> String {
                guard let index = columns[name] else { throw Malformed.missingColumn(name) }
                return values[index]
            }
            let model = Int(try value("pdbx_PDB_model_num")) ?? 1
            let atom = (name: try value("label_atom_id"),
                        residue: (Int(try value("label_seq_id")) ?? 1) - 1,
                        position: SIMD3<Float>(Float(try value("Cartn_x")) ?? 0,
                                               Float(try value("Cartn_y")) ?? 0,
                                               Float(try value("Cartn_z")) ?? 0),
                        b: Float(try value("B_iso_or_equiv")) ?? 0)
            models[model, default: []].append(atom)
            atomCount += 1
        }

        guard !models.isEmpty else { throw Malformed.noAtomSite }
        return Parsed(entryID: entryID, title: title, modelCount: models.count,
                      atomCount: atomCount,
                      models: models.keys.sorted().map { models[$0] ?? [] })
    }
}
