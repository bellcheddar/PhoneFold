import Foundation
import FoldCore
import FoldGeometry

/// Turns a provider into a stream of enriched frames.
///
/// An actor because a fold is a long-lived piece of work with state, and the app drives it
/// from the main actor while the renderer and the score consume it elsewhere.
public actor FoldEngine {

    public private(set) var configuration: FoldFrameSequence.Configuration
    /// The provider currently loaded, if any.
    public private(set) var provider: (any FoldFrameProvider)?

    public init(configuration: FoldFrameSequence.Configuration = .init()) {
        self.configuration = configuration
    }

    public func load(_ provider: some FoldFrameProvider) throws {
        guard !provider.readouts.isEmpty else { throw FoldEngineError.emptyTrajectory }
        self.provider = provider
    }

    public func update(configuration: FoldFrameSequence.Configuration) {
        self.configuration = configuration
    }

    /// The frame stream for the loaded provider.
    ///
    /// Backpressured: see `FoldFrameSequence` for why this is a pull-based `AsyncSequence`
    /// rather than an `AsyncStream`. A slow consumer slows the fold; no frame is ever lost.
    public func frames() throws -> FoldFrameSequence {
        guard let provider else { throw FoldEngineError.emptyTrajectory }
        return FoldFrameSequence(provider: provider, configuration: configuration)
    }

    /// Convenience for a one-shot fold.
    public func frames(for provider: some FoldFrameProvider) throws -> FoldFrameSequence {
        try load(provider)
        return try frames()
    }
}
