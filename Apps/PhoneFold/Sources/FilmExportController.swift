import Foundation
import SwiftUI
import Photos
import FoldCore
import FoldEngine
import FoldAudio
import FoldRender
import FoldCapture
#if canImport(UIKit)
import UIKit
#endif

/// Drives an export from a tap to a file in Photos.
///
/// **The frames are recomputed, not kept.** A 52-second fold is about 3,100 frames, and holding
/// them would be gigabytes; the trajectory is deterministic, so the export rebuilds the same
/// stream from the same provider and gets the same frames. It also means an export renders at
/// its own resolution rather than at whatever the screen happened to be.
@MainActor
final class FilmExportController: ObservableObject {

    enum State: Equatable {
        case idle
        /// Building the frame stream, before there is a fraction to report.
        case preparing
        case rendering(Double)
        case saving
        case saved(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .rendering, .saving: true
            case .idle, .saved, .failed: false
            }
        }

        /// What to put under the button.
        var message: String {
            switch self {
            case .idle: ""
            case .preparing: "Preparing…"
            case .rendering(let fraction): "Rendering \(Int(fraction * 100))%"
            case .saving: "Saving to Photos…"
            case .saved(let where_): where_
            case .failed(let why): why
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case landscape = "1080p"
        case vertical = "Vertical"
        case ultraHD = "4K"

        var id: String { rawValue }

        var size: OffscreenStage.Size {
            switch self {
            case .landscape: .landscape
            case .vertical: .vertical
            case .ultraHD: .ultraHD
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var preset: Preset = .landscape

    private var task: Task<Void, Never>?

    /// Whether the app may add to the photo library.
    ///
    /// Add-only, which is the narrowest thing that works: PhoneFold writes films and never reads
    /// the library, and asking for full access to do that would be asking for more than the
    /// feature needs.
    static func requestPhotoAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default: return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Render the fold and put the film in Photos.
    func export(provider: some FoldFrameProvider, style: StyleProfile,
                colourMode: ColourMode, name: String) {
        guard !state.isBusy else { return }
        task?.cancel()
        state = .preparing

        let preset = self.preset
        let readouts = provider.readouts.count
        let residues = provider.residues
        let metadata = provider.metadata
        let pacing = Sonifier.pacing(readouts: readouts, style: style)
        let secondsPerReadout = Float(pacing.secondsPerReadout(readouts: readouts, style: style))

        task = Task { [weak self] in
            // An export outlives a glance at another app: without this, backgrounding the app
            // part way through a two-minute render suspends it and the file is never written.
            let background = BackgroundGuard()
            defer { background.end() }

            do {
                let engine = FoldEngine(configuration: .init(
                    frameRate: 60, secondsPerRawFrame: secondsPerReadout, paced: false))
                var frames: [FoldFrame] = []
                for await frame in try await engine.frames(for: provider) {
                    if Task.isCancelled { return }
                    frames.append(frame)
                }

                var options = FilmExporter.Options()
                options.size = preset.size
                options.colourMode = colourMode
                options.caption = FilmOverlay.Caption(
                    name: metadata.name, accession: metadata.accession,
                    residueCount: residues.count,
                    confidence: frames.last?.meanPLDDT,
                    confidenceSource: metadata.provenance.confidenceSource,
                    provenance: metadata.provenance.isGenerated ? "generated" : nil)

                let url = FileManager.default.temporaryDirectory
                    .appending(path: "\(name)-\(preset.rawValue).mp4")
                let summary = try await FilmExporter(options: options).export(
                    frames: frames, residues: residues, style: style, to: url) { fraction in
                        self?.state = .rendering(fraction)
                    }
                if Task.isCancelled { return }

                self?.state = .saving
                try await Self.saveToPhotos(url)
                // The temporary file has served its purpose once Photos has a copy; leaving it
                // costs 24 MB a run in a directory nobody empties.
                try? FileManager.default.removeItem(at: url)
                self?.state = .saved(String(format: "Saved to Photos · %.0f s, %d bars",
                                            summary.videoSeconds, summary.bars))
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed("\(error)")
            }
        }
    }

    /// Put a finished film in the photo library.
    static func saveToPhotos(_ url: URL) async throws {
        guard await requestPhotoAccess() else {
            throw ExportFailure.noPhotoAccess
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset()
                .addResource(with: .video, fileURL: url, options: nil)
        }
    }

    enum ExportFailure: Error, CustomStringConvertible {
        case noPhotoAccess

        var description: String {
            "PhoneFold needs permission to add to Photos. Grant it in Settings and try again."
        }
    }
}

/// Keeps a long export running while the app is in the background.
///
/// iOS suspends an app a few seconds after it leaves the screen, which for a two-minute render
/// means a file that is never written and no error to explain it. macOS does not suspend, so
/// there is nothing to ask for there.
@MainActor
final class BackgroundGuard {
    #if canImport(UIKit) && !os(watchOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        #if canImport(UIKit) && !os(watchOS)
        identifier = UIApplication.shared.beginBackgroundTask(withName: "PhoneFold export") {
            [weak self] in self?.end()
        }
        #endif
    }

    func end() {
        #if canImport(UIKit) && !os(watchOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}
