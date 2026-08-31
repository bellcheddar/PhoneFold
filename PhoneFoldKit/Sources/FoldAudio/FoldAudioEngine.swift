import Foundation
import AVFoundation
import Synchronization
import simd
import FoldCore

/// One spatialised voice: a mono source node, and the state its render block owns.
///
/// **The handoff between threads is an ownership flip, not a lock.** While `isSounding` is
/// false the scheduler owns `voice` and may write it freely; while it is true the audio thread
/// owns it and the scheduler must not touch it. The scheduler publishes with a releasing store
/// after it has written every field, and the render block acquires before it reads one. No lock
/// is taken on the audio thread, because a lock there is a priority inversion waiting for a
/// thread the scheduler has been preempted on - which is a dropped buffer, which is a click.
final class SpatialVoice: @unchecked Sendable {
    let isSounding = Atomic<Bool>(false)
    /// Set by the scheduler to ask the audio thread to let a voice go. Read and cleared there.
    let releaseRequested = Atomic<Bool>(false)
    /// Monotonic, so the scheduler can find the oldest voice to ask for.
    let startedAt = Atomic<Int>(0)

    /// Owned by the audio thread whenever `isSounding` is true.
    var voice = SynthVoice()
    /// The node itself, which conforms to `AVAudio3DMixing` and carries its own position.
    ///
    /// **Deliberately not an `AVAudioMixingDestination`.** Holding one crashed at teardown -
    /// `EXC_BAD_ACCESS` inside `AVAudio3DMixingImpl::~AVAudio3DMixingImpl` - because a
    /// destination keeps an unowned reference to its mixer, and the engine released the
    /// environment node before this array of voices. Setting `position` on the node needs no
    /// second object and has no second lifetime to get wrong.
    var node: AVAudioSourceNode?

    /// Render this voice into an audio buffer list. Called on the audio thread only.
    func render(frames: AVAudioFrameCount, into list: UnsafeMutableAudioBufferListPointer,
                sampleRate: Double) {
        let count = Int(frames)
        guard let buffer = list.first,
              let raw = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let output = UnsafeMutableBufferPointer(start: raw, count: count)
        for i in 0..<count { output[i] = 0 }

        guard isSounding.load(ordering: .acquiring) else { return }
        if releaseRequested.exchange(false, ordering: .relaxed) { voice.release() }

        // The pool is mono into the environment node: spatialisation is the environment's job,
        // and a stereo input would be downmixed before it ever got there. Both channels of the
        // voice carry the same signal at centre pan, so rendering into one and discarding the
        // other is the mono sum without a second buffer.
        var discard = [Float](repeating: 0, count: count)
        discard.withUnsafeMutableBufferPointer { spare in
            voice.render(left: output, right: spare, range: 0..<count, sampleRate: sampleRate)
        }
        if !voice.isActive { isSounding.store(false, ordering: .releasing) }
    }
}

/// The live audio path: synthesised voices, positioned in three dimensions, played through
/// `AVAudioEngine`.
///
/// PLAN.md: "`AVAudioEnvironmentNode` with HRTF for **spatial audio**: each residue's note is
/// positioned at that residue's live 3D coordinate, so the fold collapses around the listener
/// on headphones."
///
/// So every note is its own spatialised source. A pool of mono `AVAudioSourceNode`s feeds one
/// `AVAudioEnvironmentNode`, and when a note starts, its node is placed at the coordinate of
/// the residue that produced it - the midpoint of the pair, for a contact. As the fold
/// collapses, the sources converge on the listener because the protein does.
///
/// **Nothing here re-implements the scheduling.** It drives the same `MusicalClock` and the
/// same `SynthVoice` the offline renderer does, so the WAV Marc auditions is the piece the app
/// plays rather than an approximation of it.
public final class FoldAudioEngine: @unchecked Sendable {

    /// How many notes may be spatialised at once.
    ///
    /// Fewer than the offline pool's thirty-two: each one is an HRTF-convolved source, and
    /// sixteen is what a phone can carry. A note that finds no slot is counted rather than
    /// stealing one, because stealing would mean writing state the audio thread owns.
    public static let spatialVoices = 16

    /// Angstroms per metre in the listener's world.
    ///
    /// A folded protein is tens of angstroms across. Placed one-to-one it would sit tens of
    /// metres away and the whole piece would arrive from a point; at this scale a 30 A protein
    /// is about a metre and a half wide, which is a stage a listener is standing inside.
    public static let angstromsPerMetre: Float = 20

    public let sampleRate: Double
    public private(set) var style: StyleProfile
    public let residueCount: Int

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let voices: [SpatialVoice]
    /// Read only on the scheduler thread, at note-on. Never on the audio thread, which reads
    /// the copy already inside its own voice.
    private var specs: [RenderVoiceSpec]
    /// A style change waiting for its beat: the timbres, and the time they take effect.
    private var pendingSpecs: (specs: [RenderVoiceSpec], from: Double)?

    /// Guarded by `state`, and touched only from the scheduler, never the audio thread.
    private struct Scheduling {
        var clock = MusicalClock()
        var due: [ScheduledNote] = []
        var positions: [SIMD3<Float>] = []
        var counter = 0
        var droppedForPolyphony = 0
        /// Where the protein is, in the listener's world. Inside the lock with the coordinates
        /// it applies to, because the two are read together and a stage that changed between
        /// them would place one note of a chord somewhere else.
        var stage = SpatialStage()
    }
    private let state = Mutex(Scheduling())

    public private(set) var isRunning = false
    private var hasCaptureTap = false

    deinit {
        // Torn down explicitly and in order. Left to Swift's own release order the nodes
        // outlive the engine that owns their graph, which is how the destination crash found
        // its way in.
        if hasCaptureTap { engine.mainMixerNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
        for slot in voices {
            if let node = slot.node { engine.detach(node) }
            slot.node = nil
        }
    }

    public init(style: StyleProfile, residueCount: Int, sampleRate: Double = 48_000) {
        self.style = style
        self.residueCount = Swift.max(residueCount, 1)
        self.sampleRate = sampleRate

        var table = [RenderVoiceSpec](repeating: RenderVoiceSpec(VoiceSpec()),
                                      count: Voice.allCases.count)
        for voice in Voice.allCases { table[voice.slot] = RenderVoiceSpec(style.spec(voice)) }
        specs = table
        pendingSpecs = nil
        voices = (0..<Self.spatialVoices).map { _ in SpatialVoice() }

        state.withLock { $0.due.reserveCapacity(256) }
        build()
    }

    private func build() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(environment)
        // Inside the head by default, so a protein centred on the origin surrounds the
        // listener rather than sitting in front of them.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        for slot in voices {
            let rate = sampleRate
            let node = AVAudioSourceNode(format: format) { [weak slot] _, _, frames, abl in
                guard let slot else { return noErr }
                slot.render(frames: frames,
                            into: UnsafeMutableAudioBufferListPointer(abl),
                            sampleRate: rate)
                return noErr
            }
            slot.node = node
            engine.attach(node)
            engine.connect(node, to: environment, format: format)
            // HRTF, not the cheaper panning algorithms: PLAN.md asks for the fold to collapse
            // around the listener on headphones, and only HRTF puts a source behind them.
            node.renderingAlgorithm = .HRTF
        }
    }

    // MARK: - Transport

    public enum Failure: Error, CustomStringConvertible {
        case couldNotStart(String)
        public var description: String {
            switch self {
            case .couldNotStart(let reason): "The audio engine could not start: \(reason)"
            }
        }
    }

    public func start() throws {
        guard !isRunning else { return }
        try configureSession()
        engine.prepare()
        do { try engine.start() } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        allNotesOff()
        engine.stop()
        isRunning = false
    }

    /// Stop rendering without tearing the graph down.
    ///
    /// **`pause()` rather than `stop()`, and the difference is the whole point.** `stop()`
    /// releases the render resources and resets the node timelines, so resuming would restart
    /// the piece from zero. `pause()` freezes them, which also freezes `audioTime` - and since
    /// the conductor derives its clock from `audioTime`, the score stops advancing on its own
    /// without a second timebase to keep in step. Pausing the audio pauses the music by
    /// construction rather than by arrangement.
    ///
    /// Every sounding note is released first: a paused engine holds its buffers, so a note left
    /// on would resume as a click a minute later.
    public func pause() {
        guard isRunning else { return }
        allNotesOff()
        engine.pause()
        isRunning = false
    }

    /// Carry on from where `pause()` left off.
    ///
    /// The session is not reconfigured and the graph is not rebuilt: both survive a pause, and
    /// touching them is what would reset the timeline this is trying to preserve.
    public func resume() throws {
        guard !isRunning else { return }
        do { try engine.start() } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        isRunning = true
    }

    private func configureSession() throws {
        // macOS has no AVAudioSession at all; it uses the default output device. The other
        // three platforms need `.playback` so the piece keeps going with the screen locked and
        // is not silenced by the ring switch.
        #if os(iOS) || os(watchOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            try session.setActive(true)
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        #endif
    }

    public func allNotesOff() {
        for slot in voices {
            slot.releaseRequested.store(true, ordering: .releasing)
        }
    }

    public func reset() {
        allNotesOff()
        state.withLock {
            $0.clock.reset()
            $0.due.removeAll(keepingCapacity: true)
        }
    }

    /// Take on a new style's timbres from a given time onward.
    ///
    /// **Quantised, not immediate.** Notes are placed on the timeline up to four seconds ahead,
    /// so swapping the timbres outright would retimbre notes that were written under the old
    /// style and are already on their way - the switch would arrive early and raggedly. Each
    /// note is given the voices that were in force when its own onset falls.
    public func adopt(_ newStyle: StyleProfile, from time: Double) {
        var table = [RenderVoiceSpec](repeating: RenderVoiceSpec(VoiceSpec()),
                                      count: Voice.allCases.count)
        for voice in Voice.allCases { table[voice.slot] = RenderVoiceSpec(newStyle.spec(voice)) }
        style = newStyle
        pendingSpecs = (table, time)
    }

    /// The timbres in force for a note starting at a given time.
    private func voiceSpecs(at time: Double) -> [RenderVoiceSpec] {
        guard let pending = pendingSpecs else { return specs }
        guard time >= pending.from else { return specs }
        // The switch has arrived: adopt it, so later notes need no comparison.
        specs = pending.specs
        pendingSpecs = nil
        return specs
    }

    // MARK: - Feeding it

    /// Hand the engine a bar of music, and where the protein currently is.
    ///
    /// The coordinates are this frame's alpha carbons. They are stored rather than read later,
    /// because by the time a note starts the fold has moved on and the position the note
    /// belongs at is the one its own readout had.
    @discardableResult
    public func submit(_ moment: ScoreMoment, positions: [SIMD3<Float>]) -> Bool {
        state.withLock {
            $0.positions = positions
            return $0.clock.submit(moment)
        }
    }

    /// Where the protein is, in the listener's world.
    ///
    /// PLAN.md Phase 5c: in the concert hall, "spatial audio finally does what the Phase 3
    /// design always intended: notes arrive from where their residues actually are."
    ///
    /// **Default unchanged, and deliberately so.** The default is the protein wrapped around
    /// the listener at 20 angstroms to the metre - the Phase 3 design, which has been listened
    /// to. What it does not do is turn: the stage rotates the protein and the sound stays put,
    /// so on a headset a residue you can see on your left arrives from somewhere else. That
    /// only matters where the picture and the listener share a space, which is visionOS, so
    /// that is the surface that sets this and nothing else changes. Nobody here can hear it.
    public func setStage(_ stage: SpatialStage) {
        state.withLock { $0.stage = stage }
    }

    /// Start whatever is due at `time`, in seconds from the start of playback.
    ///
    /// Called from the scheduler, never from the audio thread: it allocates nothing, but it
    /// does take a lock and set node positions, and neither belongs in a render block.
    public func pump(to time: Double) {
        var starting: [(ScheduledNote, SIMD3<Float>)] = []
        state.withLock { scheduling in
            scheduling.clock.advance(to: time, into: &scheduling.due)
            for scheduled in scheduling.due {
                starting.append((scheduled, Self.position(of: scheduled.note,
                                                          in: scheduling.positions,
                                                          stage: scheduling.stage)))
            }
            scheduling.due.removeAll(keepingCapacity: true)
        }
        for (scheduled, position) in starting { start(scheduled, at: position) }
    }

    /// Where a note sits in the listener's world.
    ///
    /// A contact belongs at the midpoint of its two partners, because that is where the contact
    /// physically is. A note whose residue has no coordinate - a chain shorter than the score
    /// thinks, a frame not yet delivered - is placed at the centre rather than dropped.
    static func position(of note: NoteEvent,
                         in coordinates: [SIMD3<Float>],
                         stage: SpatialStage = SpatialStage()) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var count: Float = 0
        for index in note.spatialResidues where coordinates.indices.contains(index) {
            total += coordinates[index]
            count += 1
        }
        guard count > 0 else { return stage.centre }
        return stage.place(total / count)
    }

    private func start(_ scheduled: ScheduledNote, at position: SIMD3<Float>) {
        let note = scheduled.note
        var chosen: SpatialVoice?
        var oldest: SpatialVoice?
        var oldestAge = Int.max
        for slot in voices {
            if !slot.isSounding.load(ordering: .acquiring) { chosen = slot; break }
            let age = slot.startedAt.load(ordering: .relaxed)
            if age < oldestAge { oldestAge = age; oldest = slot }
        }
        guard let slot = chosen else {
            // Every voice is sounding. Ask the oldest to let go - it is the one nearest to
            // finishing - and count this note as lost. Writing over a sounding voice is not an
            // option: the audio thread owns that memory while it sounds.
            oldest?.releaseRequested.store(true, ordering: .releasing)
            state.withLock { $0.droppedForPolyphony += 1 }
            return
        }

        let counter = state.withLock { scheduling -> Int in
            scheduling.counter += 1
            return scheduling.counter
        }
        slot.voice.start(frequency: note.note.frequency,
                         velocity: Double(note.note.velocity) / 127,
                         spec: voiceSpecs(at: scheduled.time)[note.voice.slot],
                         timbre: scheduled.timbre,
                         sampleRate: sampleRate,
                         tag: counter,
                         residue: note.residue,
                         partner: note.partner ?? -1,
                         pan: 0)   // Centre: the environment node does the placing.
        slot.node?.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        slot.startedAt.store(counter, ordering: .relaxed)
        // Published last, and with a releasing store: everything above must be visible to the
        // audio thread before it is allowed to look.
        slot.isSounding.store(true, ordering: .releasing)
    }

    // MARK: - What it measured about itself

    public var soundingVoices: Int {
        voices.count { $0.isSounding.load(ordering: .relaxed) }
    }
    public var droppedForPolyphony: Int { state.withLock { $0.droppedForPolyphony } }
    public var starvedBeats: Int { state.withLock { $0.clock.starvedBeats } }
    public var refusedNotes: Int { state.withLock { $0.clock.refusedNotes } }
    /// When the next submitted moment will begin, so a producer can tell whether to send more.
    public var nextBeat: Double { state.withLock { $0.clock.nextBeat } }

    /// The audio clock, in seconds since the engine started rendering.
    ///
    /// Read from the output node rather than counted on the main thread: the music has to run
    /// on the clock that actually plays it, or it drifts against the samples by however much
    /// the UI thread is late.
    public var audioTime: Double? {
        guard let render = engine.outputNode.lastRenderTime, render.isSampleTimeValid else {
            return nil
        }
        return Double(render.sampleTime) / render.sampleRate
    }

    // MARK: - The capture path

    /// Listen to the finished mix.
    ///
    /// PLAN.md: "Tap `mainMixerNode` for the Phase 4 capture path." Installed here rather than
    /// in Phase 4 because the mixer belongs to this engine, and a capture path that reached
    /// into it from outside would be one more thing to keep in step with the graph.
    ///
    /// **The block runs on the audio thread.** It must not allocate, must not lock, and must
    /// not call back into this engine - copy the samples out and do the work elsewhere.
    public func installCaptureTap(bufferSize: AVAudioFrameCount = 4_096,
                                  _ block: @escaping AVAudioNodeTapBlock) {
        removeCaptureTap()
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: bufferSize,
                         format: mixer.outputFormat(forBus: 0), block: block)
        hasCaptureTap = true
    }

    public func removeCaptureTap() {
        guard hasCaptureTap else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        hasCaptureTap = false
    }

    // MARK: - Offline, through the real graph

    /// Render the graph itself, without a device.
    ///
    /// Not the same thing as `OfflineRender`, and both are wanted: that one proves the score
    /// and the synthesis, this one proves the *graph* - the environment node, the HRTF, the
    /// connections and the render blocks - on a machine with no audio hardware and inside a
    /// test.
    public func renderOffline(seconds: Double,
                              feed: (_ time: Double, _ engine: FoldAudioEngine) -> Void)
        throws -> (left: [Float], right: [Float]) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 1_024)
        defer { engine.disableManualRenderingMode() }
        do { try engine.start() } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        defer { engine.stop() }

        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return (left, right) }

        var written = 0
        while written < total {
            let now = Double(written) / sampleRate
            feed(now, self)
            pump(to: now)
            let frames = AVAudioFrameCount(Swift.min(Int(buffer.frameCapacity), total - written))
            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success, let channels = buffer.floatChannelData else { break }
            let produced = Int(buffer.frameLength)
            for i in 0..<produced {
                left[written + i] = channels[0][i]
                right[written + i] = channels[buffer.format.channelCount > 1 ? 1 : 0][i]
            }
            written += produced
            if produced == 0 { break }
        }
        return (left, right)
    }
}
