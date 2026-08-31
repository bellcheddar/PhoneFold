import SwiftUI
import UniformTypeIdentifiers
import FoldCore
import FoldAudio
import FoldEngine
import FoldCapture

/// Studio's batch surface: drop a FASTA or a list of accessions, fold them all, walk away.
///
/// PLAN.md Phase 5a: "drop a multi-record FASTA or a list of accessions, fold them all, produce
/// a film per protein overnight."
///
/// It drives exactly the same `BatchRunner` and `BatchDelivery` the `fold-batch` command line
/// does. That is the point of both of those existing: this window is a way of choosing options
/// and watching progress, not a second implementation of batching that could disagree with the
/// first about what a batch produces.
@MainActor
final class BatchController: ObservableObject {

    @Published var input: BatchInput?
    @Published var sourceName = ""
    @Published private(set) var isRunning = false
    @Published private(set) var current = ""
    @Published private(set) var completed = 0
    @Published private(set) var results: [BatchRunner.Result] = []
    @Published private(set) var report = ""

    @Published var engine: FoldingEngine = .structureBased
    @Published var styleID = "fantasy"
    @Published var formats = BatchDelivery.Formats(mmCIF: true, film: true)
    @Published var destination: URL?

    private var task: Task<Void, Never>?

    var total: Int { input?.items.count ?? 0 }

    /// Read a dropped or chosen file.
    func load(_ url: URL) {
        // A batch list is a text file whatever it is called: `.fasta`, `.fa`, `.txt`, or the
        // extensionless thing that comes out of a database export.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            report = "Could not read \(url.lastPathComponent) as text."
            return
        }
        input = BatchInput.parse(text)
        sourceName = url.lastPathComponent
        results = []
        report = ""
        if destination == nil {
            destination = url.deletingLastPathComponent()
                .appending(path: url.deletingPathExtension().lastPathComponent + "-folds")
        }
    }

    func run(styles: [String: StyleProfile]) {
        guard let input, !isRunning, let destination else { return }
        guard let style = styles[styleID] ?? styles.values.first else {
            report = "No style profiles are bundled."
            return
        }
        isRunning = true
        results = []
        completed = 0
        report = ""

        let delivery = BatchDelivery(formats: formats, style: style, directory: destination)
        let runner = BatchRunner(engine: engine)

        task = Task { [weak self] in
            let summary = await runner.run(
                input,
                resolve: { try await AlphaFoldClient().reference(for: $0) },
                progress: { index, _, identifier in
                    Task { @MainActor in
                        self?.current = identifier
                        self?.completed = index
                    }
                },
                deliver: { bundle, item in
                    try await delivery.write(bundle, stem: item.label ?? item.accession)
                })
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.results = summary.results
                self.report = summary.report
                self.completed = summary.results.count
                self.current = ""
                self.isRunning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        current = ""
    }
}

struct BatchWindow: View {
    @StateObject private var controller = BatchController()
    @State private var isTargeted = false

    /// The same bundled profiles the stage plays. Loaded here rather than taken from a
    /// `FoldPlayer`, because a batch window has no fold of its own to borrow one from.
    private let styles: [String: StyleProfile] = (try? StyleLibrary.bundled()) ?? [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone

            if let input = controller.input {
                summary(input)
                options
                transport
            }

            if !controller.report.isEmpty {
                ScrollView {
                    Text(controller.report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .navigationTitle("Batch Fold")
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(height: 92)
            .overlay {
                VStack(spacing: 4) {
                    Text(controller.sourceName.isEmpty
                         ? "Drop a FASTA or a list of accessions"
                         : controller.sourceName)
                        .font(.headline)
                    Text("One identifier per line, or UniProt FASTA headers. "
                         + "UniProt accessions and PDB entry ids both work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadTransferable(type: URL.self) { result in
                    if case .success(let url) = result {
                        Task { @MainActor in controller.load(url) }
                    }
                }
                return true
            }
            .onTapGesture { choose() }
            .accessibilityLabel("Batch input file")
            .accessibilityHint("Drop a FASTA or accession list here, or click to choose one")
    }

    private func summary(_ input: BatchInput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(input.items.count) to fold"
                 + (input.rejections.isEmpty ? ""
                    : ", \(input.rejections.count) not read"))
                .font(.subheadline.weight(.medium))
            // The rejections are shown before the run rather than after it. A file whose
            // headers carry no accession produces an empty batch, and finding that out in the
            // morning is the failure this whole surface exists to avoid.
            if !input.rejections.isEmpty {
                ForEach(Array(input.rejections.prefix(4).enumerated()), id: \.offset) { _, r in
                    Text(r.line > 0 ? "line \(r.line): \(r.reason)" : r.reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if input.rejections.count > 4 {
                    Text("and \(input.rejections.count - 4) more")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Engine", selection: $controller.engine) {
                ForEach(FoldingEngine.allCases.filter(\.needsReferenceStructure), id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            HStack(spacing: 14) {
                Toggle("mmCIF", isOn: $controller.formats.mmCIF)
                Toggle("Film", isOn: $controller.formats.film)
                Toggle("MIDI", isOn: $controller.formats.midi)
                Toggle("Audio", isOn: $controller.formats.wav)
            }
            .toggleStyle(.checkbox)

            HStack {
                Text("Into")
                Text(controller.destination?.path ?? "-")
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary)
                Button("Change…") { chooseDestination() }
                    .buttonStyle(.link)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            if controller.isRunning {
                ProgressView(value: Double(controller.completed),
                             total: Double(max(controller.total, 1)))
                    .frame(maxWidth: 220)
                Text("\(controller.completed) of \(controller.total)  \(controller.current)")
                    .font(.caption.monospaced())
                Button("Stop") { controller.cancel() }
            } else {
                Button("Fold \(controller.total)") {
                    controller.run(styles: styles)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(controller.total == 0 || controller.destination == nil
                          || !controller.formats.wantsAnything)
                if !controller.formats.wantsAnything {
                    Text("Choose at least one output format")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.load(url) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { controller.destination = panel.url }
    }
}
