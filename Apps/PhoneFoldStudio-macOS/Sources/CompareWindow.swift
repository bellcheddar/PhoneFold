import SwiftUI
import UniformTypeIdentifiers
import FoldCore
import FoldGeometry

/// Studio's structure comparison: drop a prediction and an experimental structure.
///
/// PLAN.md Phase 5a: "Drag and drop of PDB and mmCIF files to compare a prediction against an
/// experimental structure (superpose, show RMSD per residue) - the one analytical concession,
/// because on a Mac it is expected."
///
/// **Two wells rather than one, because which file is which changes the answer.** The prediction
/// moves and the experimental structure stays put, and the deviations are reported against the
/// experimental file's residue numbering and B-factors. A single drop zone that guessed would be
/// guessing about the thing the user came to find out.
@MainActor
final class CompareController: ObservableObject {

    @Published private(set) var prediction: StructureFile?
    @Published private(set) var reference: StructureFile?
    @Published private(set) var result: StructureComparison.Result?
    @Published private(set) var message = ""
    @Published var offset = 0

    var canCompare: Bool { prediction != nil && reference != nil }

    func load(_ url: URL, asPrediction: Bool) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let structure = try StructureFile.read(
                text, identifier: url.deletingPathExtension().lastPathComponent)
            if asPrediction { prediction = structure } else { reference = structure }
            message = ""
            compare()
        } catch {
            message = "\(error)"
        }
    }

    func compare() {
        guard let prediction, let reference else { return }
        do {
            result = try StructureComparison.compare(mobile: prediction, reference: reference,
                                                     offset: offset)
            message = ""
        } catch {
            result = nil
            message = "\(error)"
        }
    }

    /// Take the offset the comparison worked out for itself.
    func applySuggestedOffset() {
        guard let suggested = result?.suggestedOffset else { return }
        offset = suggested
        compare()
    }
}

struct CompareWindow: View {
    @StateObject private var controller = CompareController()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                well(title: "Prediction", subtitle: "moves",
                     structure: controller.prediction, asPrediction: true)
                well(title: "Experimental", subtitle: "stays put",
                     structure: controller.reference, asPrediction: false)
            }

            if !controller.message.isEmpty {
                Text(controller.message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = controller.result {
                resultView(result)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .navigationTitle("Compare Structures")
    }

    private func well(title: String, subtitle: String, structure: StructureFile?,
                      asPrediction: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(Color.secondary.opacity(0.5))
            .frame(height: 96)
            .overlay {
                VStack(spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    if let structure {
                        Text(structure.identifier).font(.callout.monospaced())
                        Text("\(structure.residues.count) residues, "
                             + "chain \(structure.chains.joined(separator: ","))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Drop a PDB or mmCIF")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadTransferable(type: URL.self) { outcome in
                    if case .success(let url) = outcome {
                        Task { @MainActor in controller.load(url, asPrediction: asPrediction) }
                    }
                }
                return true
            }
            .accessibilityLabel("\(title) structure file")
            .accessibilityHint("Drop a PDB or mmCIF file here")
    }

    @ViewBuilder
    private func resultView(_ result: StructureComparison.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // **The warning replaces the number, it does not sit beside it.** A screen showing
            // "18.11 Å" with a caution underneath is a screen someone reads the number off.
            if !result.numberingAgrees {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.misregistrationWarning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let suggested = result.suggestedOffset {
                        Button("Shift the prediction by \(suggested) and compare") {
                            controller.applySuggestedOffset()
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.15)))
            } else {
                Text(result.summary)
                    .font(.title3.weight(.medium))
                    .textSelection(.enabled)
            }

            HStack {
                Text("Offset")
                TextField("0", value: $controller.offset, format: .number)
                    .frame(width: 70)
                    .onSubmit { controller.compare() }
                Text("added to the prediction's residue numbers")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if result.numberingAgrees {
                Text("Furthest from the experimental structure")
                    .font(.subheadline.weight(.medium))
                Table(result.worst(15)) {
                    TableColumn("Residue") { Text("\($0.number)").monospacedDigit() }
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Deviation") {
                        Text(String(format: "%.2f Å", $0.deviation)).monospacedDigit()
                    }
                    // The experimental B-factor beside the deviation, because a large
                    // difference where the crystal structure was itself poorly ordered is a
                    // different finding from one in a well-resolved region.
                    TableColumn("Reference B") {
                        Text(String(format: "%.1f", $0.referenceBFactor)).monospacedDigit()
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }
}

extension StructureComparison.ResidueDeviation: @retroactive Identifiable {
    public var id: Int { number }
}
