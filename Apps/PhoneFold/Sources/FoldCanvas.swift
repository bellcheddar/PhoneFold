import SwiftUI
import CoreGraphics
import RealityKit
import Metal
import simd
import FoldCore
import FoldRender
#if os(macOS)
import AppKit
#endif

/// The stage itself: the protein, drawn from the tube mesh.
///
/// RealityKit with `LowLevelMesh`, as PLAN.md Phase 2 requires, so the vertex buffer is
/// rewritten in place each frame rather than a new `MeshResource` being built. RealityKit is
/// also the visionOS path, which is why it wins over SceneKit here.
struct FoldCanvas: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var player: FoldPlayer
    @Binding var diagnostic: String
    /// How big the protein stands in the room. Passed in rather than owned, because only the
    /// immersive space has any business changing it and it has to survive the view redrawing.
    var roomScale: RoomScale = RoomScale()
    /// Where the stage sits, in metres, relative to the scene's origin.
    ///
    /// **Zero everywhere except an immersive space, where zero is the floor.** A window or a
    /// volume gives RealityKit content a bounded box with the origin in the middle of it; an
    /// `ImmersiveSpace` puts the origin on the floor at the wearer's feet, so a stage left at
    /// zero is a protein sunk into the carpet and out of view unless you look down.
    var stagePlacement: SIMD3<Float> = .zero

    @State private var stage = StageContent()
    @State private var lastDrag: CGSize = .zero
    /// Where the drag in progress began.
    ///
    /// Used to notice that a *new* gesture has started. `lastDrag` was only ever cleared in
    /// `onEnded`, and `onEnded` does not always run: a drag pre-empted by the simultaneous
    /// magnify gesture, or cancelled by the system, leaves the previous gesture's translation
    /// behind, and the next drag's first delta is then the difference between two unrelated
    /// gestures - a jump. Comparing the start location catches that without depending on
    /// `onEnded` at all.
    @State private var dragAnchor: CGPoint?

    var body: some View {
        // No `update:` closure driving the mesh. Frames arrive through the player's
        // `onFrame` sink instead, so drawing does not depend on a SwiftUI re-evaluation and
        // the fold is not paced by layout.
        RealityView { content in
            content.add(stage.root)
        }
        // A `RealityView` coordinator has no environment of its own, so the settings are read
        // here and pushed down. `.onChange` with `initial: true` rather than `.onAppear`: a
        // setting can be changed while the app is open, and a stage that only read it at
        // launch would need a relaunch to honour it.
        .onChange(of: differentiateWithoutColour, initial: true) { _, value in
            stage.accessiblePalette = value || player.accessiblePalette
        }
        .onChange(of: reduceMotion, initial: true) { _, value in
            stage.reduceMotion = value || player.reduceMotion
        }
        .onChange(of: roomScale, initial: true) { _, scale in
            stage.roomScale = scale
        }
        .onChange(of: stagePlacement, initial: true) { _, placement in
            stage.root.position = placement
        }
        // The stage is the one thing in the app with no text of its own. Merged into a single
        // element so VoiceOver reads the protein rather than nothing, and `updatesFrequently`
        // so it re-reads as the fold proceeds instead of describing frame one for a minute.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The fold")
        .accessibilityValue(player.stageDescription)
        .accessibilityAddTraits(.updatesFrequently)
        // Over the stage and nothing else, and never in the way of a gesture.
        //
        // Reduce Transparency removes it entirely rather than thinning it: the grade is a
        // translucent wash, which is precisely what the setting is asking not to be shown, and
        // a fainter wash is still a wash.
        .auroraVignette(reduceTransparency ? nil : stage.grade)
        // The grade sits directly on the RealityView's output, before the gestures, so it
        // covers exactly the stage and nothing else. `onGeometryChange` rather than a
        // GeometryReader wrapper: the reader would relayout the view it wraps, and the
        // shader needs the size only to place its radial terms.
        // **The same two gestures everywhere, attached two different ways.**
        //
        // PLAN.md Phase 5c asks for "pinch-drag to rotate, two-handed pinch to scale", and
        // the temptation is to say the phone's gestures already do that and the headset gets
        // them for free. They do not. On visionOS a gesture attached to a `RealityView`
        // receives nothing unless the pinch ray hits an entity carrying `InputTargetComponent`
        // and a `CollisionComponent`: without `targetedToAnyEntity` and the box the stage
        // installs alongside it, this is not a less precise drag, it is no drag at all, and
        // the protein cannot be turned by hand. The handlers below are shared precisely so
        // that difference stays where it belongs - in how the gesture is aimed, and nowhere
        // else.
        #if os(visionOS)
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    applyDrag(startLocation: value.gestureValue.startLocation,
                              translation: value.gestureValue.translation)
                }
                .onEnded { _ in endDrag() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .targetedToAnyEntity()
                .onChanged { applyMagnify($0.gestureValue.magnification) }
                .onEnded { _ in stage.camera.endInteraction() }
        )
        #else
        .gesture(
            DragGesture()
                .onChanged { value in
                    applyDrag(startLocation: value.startLocation, translation: value.translation)
                }
                .onEnded { _ in endDrag() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { applyMagnify($0.magnification) }
                .onEnded { _ in stage.camera.endInteraction() }
        )
        #endif
        #if os(macOS)
        // Scroll only acts over the stage itself, so the gallery and scrubber keep their
        // own scrolling. The stage's frame is tracked and the event's location hit-tested
        // against it - not `.onHover`, which measurably failed to arm under synthesised
        // pointer moves and depends on tracking-area bookkeeping this has no need of.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            stage.stageFrame = frame
        }
        #endif
        .onTapGesture(count: 2) { stage.reframe() }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                stage.updateForConditions()
            }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSProcessInfoPowerStateDidChange)) { _ in
                stage.updateForConditions()
            }
        .onAppear {
            stage.updateForConditions()
            #if os(visionOS)
            // PLAN.md Phase 5c: "spatial audio finally does what the Phase 3 design always
            // intended". The half that was missing is that the stage turns and the sound did
            // not, so a residue visibly on your left arrived from wherever it started.
            stage.onStageTransformChanged = { [player] attitude, extent in
                player.stageTransformChanged(attitude: attitude, extent: extent)
            }
            #endif
            stage.startClock()
            #if os(macOS)
            stage.installScrollMonitor()
            #endif
            stage.colourMode = player.colourMode
            stage.residues = player.provider?.residues ?? []
            stage.residueCount = player.provider?.residueCount ?? 0
            player.onFrame = { [stage] frame, flashes in
                stage.apply(frame: frame, flashes: flashes)
                diagnostic = stage.lastDiagnostic
            }
        }
        .onDisappear {
            stage.stopClock()
            stage.onStageTransformChanged = nil
            #if os(macOS)
            stage.removeScrollMonitor()
            #endif
            player.onFrame = nil
        }
        .onChange(of: player.colourMode) { _, mode in
            stage.colourMode = mode
            // Recolour immediately rather than waiting for the next frame, so switching
            // mode feels instant even on a paused or finished fold.
            if let frame = player.latestFrame { stage.apply(frame: frame, flashes: []) }
        }
        .onChange(of: player.title) { _, _ in
            stage.residues = player.provider?.residues ?? []
            stage.residueCount = player.provider?.residueCount ?? 0
            stage.reset()
        }
    }

    // MARK: - The two gestures

    /// A drag, however it was aimed.
    ///
    /// Shared between the targeted visionOS gesture and the untargeted one every other
    /// platform uses, so the two cannot drift into behaving differently. The camera model
    /// itself is in `FoldRender` and fully tested; this is only the translation from a
    /// gesture callback into calls on it.
    private func applyDrag(startLocation: CGPoint, translation: CGSize) {
        if dragAnchor != startLocation {
            dragAnchor = startLocation
            lastDrag = .zero
        }
        // Deltas, not the cumulative translation: using the total resets the rotation to
        // zero on release and snaps the view back.
        let dx = Float(translation.width - lastDrag.width)
        let dy = Float(translation.height - lastDrag.height)
        stage.camera.drag(deltaX: dx, deltaY: dy)
        lastDrag = translation
        stage.noteDrag(dx, dy)
        // Applied here rather than waiting for the next clock tick, so the rotation cannot
        // depend on that task still running.
        stage.applyCamera()
        // And the diagnostics update from the gesture itself, so a screenshot taken during a
        // stuck drag shows the state at that moment.
        diagnostic = stage.lastDiagnostic
    }

    private func endDrag() {
        lastDrag = .zero
        dragAnchor = nil
        stage.camera.endInteraction()
    }

    private func applyMagnify(_ magnification: CGFloat) {
        stage.camera.magnify(scale: Float(magnification))
        stage.noteMagnify()
        stage.applyCamera()
        diagnostic = stage.lastDiagnostic
    }

}

/// Owns the RealityKit entities, the mesh buffer and the camera across updates.
@MainActor
@Observable
final class StageContent {
    let root = Entity()
    /// What the grade is allowed to do right now, given heat and power mode.
    var grade = AuroraGrade.forCurrentConditions()
    var camera = StageCamera()

    var lastDiagnostic = ""
    var colourMode: ColourMode = .confidence
    var residues: [AminoAcid] = []
    var residueCount: Int = 0

    /// Accessibility, pushed in from the view.
    ///
    /// `Differentiate Without Color` swaps the secondary-structure palette for the amber and
    /// blue one; `Reduce Motion` stops the orbit and the contact flashes. Both are read from
    /// the environment by the view and set here, because a `RealityView` coordinator has no
    /// environment of its own.
    var accessiblePalette = false { didSet { if accessiblePalette != oldValue { rampMode = nil } } }
    var reduceMotion = false

    /// Interaction counters, on the glass under PHONEFOLD_DIAGNOSTICS=1.
    ///
    /// The stuck drag has never reproduced here, under synthesised events or otherwise, so
    /// the app now tells on itself: one screenshot during a stuck drag distinguishes "no
    /// gesture events arriving" (`drag` not climbing) from "events arriving, camera not
    /// moving" (`drag` climbing, `rot` frozen) from "the magnify pre-empted the drag"
    /// (`mag` climbing during a one-finger drag).
    private(set) var dragEvents = 0
    private(set) var magnifyEvents = 0
    private(set) var scrollEvents = 0
    /// Every scroll event the monitor saw, consumed or not: separates "no events arrive"
    /// from "events arrive but the stage hit-test rejects them".
    private(set) var scrollEventsSeen = 0
    private var lastScrollLocation = CGPoint.zero
    private var lastDragDelta = SIMD2<Float>(0, 0)
    private var meshInfo = ""
    #if os(macOS)
    /// The stage's frame in the window's SwiftUI coordinate space, kept current by
    /// `onGeometryChange`. The scroll monitor hit-tests event locations against it, which
    /// is what lets scroll act on the stage without stealing the gallery's and scrubber's
    /// own scrolling.
    var stageFrame = CGRect.zero
    private var scrollMonitor: Any?
    #endif

    func noteDrag(_ deltaX: Float, _ deltaY: Float) {
        dragEvents += 1
        lastDragDelta = SIMD2<Float>(deltaX, deltaY)
        refreshDiagnostic()
    }

    func noteMagnify() {
        magnifyEvents += 1
        refreshDiagnostic()
    }

    func refreshDiagnostic() {
        guard Diagnostics.isEnabled else { return }
        let rotation = camera.subjectRotation
        // Fold the double cover so the display never reads 350 degrees for 10.
        var angle = rotation.angle * 180 / .pi
        if angle > 180 { angle = 360 - angle }
        var scroll = "scr \(scrollEvents)"
        #if os(visionOS)
        // The one thing that cannot be told apart by looking at the stage: whether a hand has
        // anything to pinch. Reported so a screenshot shows the box is there and is the size
        // of the protein, rather than the feature being confirmed by it appearing to work.
        scroll += inputTarget.extent.map {
            String(format: " | pinch box %.0fx%.0fx%.0f A", $0.x, $0.y, $0.z)
        } ?? " | pinch box NONE"
        #endif
        #if os(macOS)
        scroll += String(format: "/%d sf(%.0f,%.0f,%.0f,%.0f) at(%.0f,%.0f)",
                         scrollEventsSeen, stageFrame.origin.x, stageFrame.origin.y,
                         stageFrame.width, stageFrame.height,
                         lastScrollLocation.x, lastScrollLocation.y)
        #endif
        lastDiagnostic = String(
            format: "rot %.0f° d %.2f %@ | drag %d Δ(%.1f,%.1f) mag %d ",
            angle, camera.distance, camera.isOrbiting ? "orbiting" : "held",
            dragEvents, lastDragDelta.x, lastDragDelta.y, magnifyEvents)
            + scroll + " | " + meshInfo
    }

    #if os(macOS)
    /// PLAN.md: "Mac adds scroll-wheel zoom". A local monitor rather than a SwiftUI
    /// gesture, because SwiftUI has no scroll gesture on macOS: a trackpad's two-finger
    /// swipe and a mouse wheel both arrive only as `.scrollWheel` events.
    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            let delta = Float(event.scrollingDeltaY)
            let precise = event.hasPreciseScrollingDeltas
            // The event's location, in the window's SwiftUI space: AppKit measures from
            // the bottom-left, SwiftUI's hosting view from the top-left.
            guard let contentView = event.window?.contentView else { return event }
            let inView = contentView.convert(event.locationInWindow, from: nil)
            let location = contentView.isFlipped
                ? inView
                : CGPoint(x: inView.x, y: contentView.bounds.height - inView.y)
            // Local monitors are delivered on the main thread with the event loop; the
            // event itself is not Sendable, so only plain values cross into the actor.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.scrollEventsSeen += 1
                self.lastScrollLocation = location
                guard self.stageFrame.contains(location),
                      delta.isFinite, delta != 0 else {
                    self.refreshDiagnostic()
                    return false
                }
                // Precise deltas arrive in points (trackpad, Magic Mouse); line-based
                // wheels arrive in notches, each worth far more.
                self.camera.zoom(steps: delta * (precise ? 0.003 : 0.05))
                self.scrollEvents += 1
                self.applyCamera()
                return true
            }
            return consumed ? nil : event
        }
    }

    func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    #endif

    private let protein = ModelEntity()
    private let cameraEntity = Entity()
    private var tubeMesh: LowLevelTubeMesh?
    private var vertexCapacity = 0
    private var material: RealityKit.Material?
    /// Cached per-bucket materials, keyed by the bucket colours they were built from.
    ///
    /// The bucket colours are quantised, so they change far less often than the frame rate:
    /// rebuilding a material per bucket per frame was allocating ~29 materials sixty times a
    /// second for colours that were usually identical to the previous frame's.
    /// Which mode the current ramp texture was built for.
    private var rampMode: ColourMode?
    /// The halo shell. A second entity so it can carry its own translucent material and
    /// its own culling without disturbing the tube's per-bucket parts.
    private let outline = ModelEntity()
    private var outlineMesh: LowLevelTubeMesh?
    /// The shell of the last frame, kept so the halo can be re-culled when the protein turns
    /// without waiting for the next frame. The auto-orbit outlives playback, so a halo that
    /// only refreshed on new frames would freeze at the last frame's silhouette and then
    /// slide visibly out of register as the protein kept turning.
    private var outlineShell: [RenderVertex] = []
    private var outlineTint = SIMD3<Float>(0.5, 0.5, 0.6)
    private var outlineIndices: [UInt32] = []
    private var clock: Task<Void, Never>?
    private var lastBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?
    /// How big the protein stands in the room. 1 is the stage's ordinary framing.
    ///
    /// PLAN.md Phase 5c's "walk into the core". visionOS only in practice, because it is the
    /// only surface where the viewer has a body in the same space as the protein - on a phone
    /// growing the protein past the frame just crops it.
    var roomScale = RoomScale() {
        didSet { if roomScale != oldValue { applyProteinTransform() } }
    }

    /// The box a hand has to pinch, and when it needs rebuilding. See `InputTargetShape`.
    ///
    /// visionOS only, because it is the only surface where a gesture has to *hit* something
    /// before it is delivered. On the phone and the Mac the drag lands on the view and a
    /// collision shape would be geometry nothing reads.
    private var inputTarget = InputTargetShape()

    init() {
        root.addChild(protein)
        // A child of the protein, not of the root. The camera's orbit and the framing scale
        // are applied to the protein's transform, so a halo parented to the root is drawn at
        // raw angstrom scale and unrotated: it filled the whole stage as a pale blob, which
        // looks like a broken material rather than a misplaced entity.
        protein.addChild(outline)
        // An explicit camera, rather than relying on RealityView's default framing. Without
        // one the protein renders correctly but tiny, because the default camera sits far
        // enough back to frame a room-scale scene.
        // near 0.05 and far 20, not 0.01 and 100.
        //
        // The depth buffer's precision is governed by the ratio of the two, and 10,000 to 1
        // spends almost all of it on the first fraction of the scene. The protein is scaled to
        // about 1.15 units and the camera sits at 1.5, so a ribbon 0.5 A thick is roughly 0.03
        // units and the outline stands 0.005 units off the surface - both inside the noise at
        // that ratio, which is what put dark creases along the ribbons and slits through the
        // helices. 400 to 1 gives twenty-five times the precision where the protein actually
        // is, and still clears the closest the camera can be brought (0.35).
        cameraEntity.components.set(PerspectiveCameraComponent(near: 0.05, far: 20,
                                                               fieldOfViewInDegrees: 42))
        root.addChild(cameraEntity)
        // **The same rig the offscreen renderer uses**, from `FoldRender`, rather than
        // `RealityView`'s implicit default environment. PLAN's Phase 4 gate is that an export
        // and the live view look identical, and a default on one side against explicit lights
        // on the other cannot give that. Marc's call, 2026-08-31.
        for light in StageLighting.makeLights() { root.addChild(light) }
        applyCamera()
    }

    /// Drives the automatic orbit. Separate from the fold's own clock so interaction stays
    /// responsive whatever the engine is doing: PLAN.md requires interaction never to block
    /// or delay the fold.
    /// Re-read the thermal state and power mode, and rebuild the halo if the answer changed.
    ///
    /// Sampled once at init the grade would never degrade, which is the failure mode that
    /// looks like it works: the device gets hot on the exact long fold where the policy was
    /// supposed to help, and nothing happens.
    func updateForConditions() {
        let updated = AuroraGrade.forCurrentConditions()
        guard updated != grade else { return }
        grade = updated
        if grade.outlineOpacity <= 0 || grade.outlineWidth <= 0 {
            outline.model = nil
            outlineMesh = nil
            outlineShell = []
        } else {
            refreshOutline()
        }
    }

    func startClock() {
        guard clock == nil else { return }
        clock = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard let self else { return }
                let now = Date()
                // Reduce Motion stops the automatic orbit outright rather than slowing it. A
                // slow drift is still drift, and the setting exists for people for whom that
                // is the problem; a drag still turns the protein, so nothing is lost but the
                // motion nobody asked for.
                if !self.reduceMotion {
                    self.camera.advance(deltaTime: Float(now.timeIntervalSince(last)))
                    self.applyCamera()
                }
                last = now
            }
        }
    }

    func stopClock() {
        clock?.cancel()
        clock = nil
    }

    func reframe() {
        camera.reframe(bounds: lastBounds)
        applyCamera()
    }

    /// Apply the camera by moving the **protein**, not the camera entity.
    ///
    /// A camera entity with a non-identity rotation stopped the scene rendering entirely:
    /// RealityView's handling of a supplied `PerspectiveCameraComponent` in a non-AR context
    /// is not something to fight blind. Orbiting the subject against a fixed camera is
    /// visually identical for an orbit rig, and it is the arrangement that demonstrably
    /// renders. The `StageCamera` model is unchanged and still fully tested; only where its
    /// transform is applied has moved.
    func applyCamera() {
        cameraEntity.transform = Transform(
            scale: .one,
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            translation: SIMD3<Float>(0, 0, camera.distance))
        applyProteinTransform()
        refreshDiagnostic()
    }

    /// The camera's position in the mesh's own space.
    ///
    /// The camera sits on +Z at `camera.distance` and the orbit is applied to the protein, so
    /// this undoes the protein's transform rather than moving the camera. The halo's culling
    /// needs the eye rather than a view axis because the projection is perspective: one axis
    /// for the whole mesh is the orthographic approximation, and it selects the wrong band of
    /// triangles toward the edges of the frame.
    private func eyeInMeshSpace() -> SIMD3<Float> {
        guard let bounds = lastBounds else { return SIMD3<Float>(0, 0, camera.distance) }
        let extent = simd_length(bounds.maximum - bounds.minimum)
        let scale = framingScale(for: extent)
        let centre = (bounds.maximum + bounds.minimum) * 0.5
        let rotation = proteinRotation()
        let eyeInRoot = SIMD3<Float>(0, 0, camera.distance)
        return rotation.inverse.act(eyeInRoot) / scale + centre + camera.target
    }

    /// Shared with the halo's culling, which has to use exactly this rotation: derived
    /// separately, the two drift apart and the halo lights the wrong side of the protein.
    private func proteinRotation() -> simd_quatf { camera.subjectRotation }

    /// Told whenever the protein's orientation or size changes, so the spatial audio can
    /// follow it. Set by `FoldCanvas` on visionOS and left nil everywhere else: it is the only
    /// surface where the picture and the listener share a space.
    var onStageTransformChanged: ((simd_quatf, Float) -> Void)?

    /// The stage normalises every protein to the same size so the framing does not depend on
    /// whether it is 20 residues or 300, then `roomScale` grows it into the room.
    private func framingScale(for extent: Float) -> Float {
        let framed = extent > 0.001 ? RoomScale.framedExtent / extent : 1
        return framed * roomScale.multiplier
    }

    private func applyProteinTransform() {
        guard let bounds = lastBounds else { return }
        let extent = simd_length(bounds.maximum - bounds.minimum)
        let scale = framingScale(for: extent)
        let centre = (bounds.maximum + bounds.minimum) * 0.5
        let rotation = proteinRotation()
        protein.transform = Transform(scale: SIMD3<Float>(repeating: scale),
                                      rotation: rotation,
                                      translation: rotation.act(-(centre + camera.target) * scale))
        refreshOutline()
        // After the transform, not before: the sound follows the picture, and reporting the
        // rotation the picture is about to have would put them a frame apart.
        onStageTransformChanged?(rotation, extent)
    }

    /// Keep the box a pinch has to hit in step with the protein it is meant to be.
    ///
    /// In the protein's own space, not the stage's: the entity's transform already carries
    /// the framing scale and the orbit, so a box built in stage units would be scaled twice
    /// and the hand would grab a protein-shaped region a fraction of the protein's size.
    ///
    /// A no-op on every platform but visionOS. `InputTargetShape` decides *when* this is
    /// stale, and it is a value type in `FoldRender` so that decision is tested without a
    /// headset - see `InputTargetShapeTests`.
    private func refreshInputTarget(bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)) {
        #if os(visionOS)
        guard let box = inputTarget.update(bounds: bounds) else { return }
        let shape = ShapeResource.generateBox(size: box.size)
            .offsetBy(translation: box.centre)
        protein.components.set(CollisionComponent(shapes: [shape], isStatic: false))
        // Idempotent, and set here rather than once in `init` so the two always arrive
        // together: an input target with no collision shape is hit by nothing, and the
        // failure is a gesture that silently never fires.
        protein.components.set(InputTargetComponent())
        #endif
    }

    /// Reset when the protein changes, so the mesh is reallocated for the new topology.
    func reset() {
        tubeMesh = nil
        vertexCapacity = 0
        rampMode = nil
        // A new protein is a new shape; the pinch box must not be left sized for the old one.
        inputTarget.invalidate()
    }

    func apply(frame: PreparedFrame, flashes: [FlashInstance]) {
        let mesh = frame.mesh
        guard !mesh.vertices.isEmpty else { return }

        let options = ColourOptions(residueCount: residueCount, residues: residues,
                                    accessiblePalette: accessiblePalette)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: frame.confidence,
                                         mode: colourMode, options: options)

        // One part, one material, and the colour comes out of a ramp texture that each vertex
        // indexes through uv0. This replaced splitting the mesh into a part per quantised
        // colour: every part was one flat tint, so the ramp arrived as a visible staircase -
        // 26 measurable steps along a single strand ribbon - and making the quantisation finer
        // cost memory as the cube of the level count. See `ColourRamp`.
        if tubeMesh == nil || vertexCapacity != packed.count {
            // Not `try?`: swallowing this hid a mesh that never got built, and the symptom
            // was an empty stage with no error anywhere.
            do {
                let built = try LowLevelTubeMesh(template: mesh)
                tubeMesh = built
                vertexCapacity = packed.count
                protein.model = ModelComponent(mesh: try built.resource(),
                                               materials: [proteinMaterial(options: options)])
            } catch {
                print("PHONEFOLD: mesh build FAILED: \(error)")
                return
            }
        }
        if Diagnostics.isEnabled {
            meshInfo = "tri=\(mesh.indices.count / 3) "
                + "idx=\(mesh.indices.count)/\(tubeMesh?.indexCapacity ?? 0) "
                + "v=\(packed.count)/\(vertexCapacity)"
            refreshDiagnostic()
        }
        do {
            try tubeMesh?.update(vertices: packed)
            if rampMode != colourMode, var component = protein.model {
                component.materials = [proteinMaterial(options: options)]
                protein.model = component
            }
        } catch {
            print("PHONEFOLD: vertex update FAILED: \(error)")
        }

        updateOutline(mesh: mesh, packed: packed)

        // Normalise so the framing does not depend on whether the protein is 20 residues
        // or 300, then apply the camera's orbit to it.
        if let bounds = TubeMeshPacker.bounds(packed) {
            lastBounds = bounds
            applyProteinTransform()
            refreshInputTarget(bounds: bounds)
        }

        // Follow the action: ease toward where contacts are forming, in the protein's own
        // normalised space.
        if !flashes.isEmpty, !reduceMotion, let bounds = lastBounds {
            let extent = simd_length(bounds.maximum - bounds.minimum)
            let scale = extent > 0.001 ? 1.0 / extent : 1
            let centre = (bounds.maximum + bounds.minimum) * 0.5
            camera.followAction(midpoints: flashes.map { ($0.midpoint - centre) * scale })
            applyProteinTransform()
        }
    }

    /// One stock material per colour bucket.
    ///
    /// **Not a `CustomMaterial`.** That would read the per-vertex colour directly, but its
    /// pipeline fails to compile on the Simulator - `fsSurfacePbr` reports "Constant buffer
    /// count [16] exceeds limit [14]" - and the failure is silent: the mesh is present, the
    /// material is assigned, and nothing draws. Bisecting with a `SimpleMaterial` rendered
    /// the identical mesh correctly, which is what sent the colour through mesh parts
    /// instead. Stock materials work on every platform and need no shader to be verified on
    /// hardware first.
    /// Rebuild the halo shell from the tube that was just drawn.
    ///
    /// The offset is a fraction of the coil radius rather than an absolute distance, so the
    /// halo keeps its proportion when the cross section morphs: a helix is thicker than a
    /// coil and a sheet is a flat ribbon, and a fixed offset would give the ribbon a halo
    /// several times its own thickness.
    private func updateOutline(mesh: TubeMesh, packed: [RenderVertex]) {
        guard grade.outlineOpacity > 0, grade.outlineWidth > 0 else {
            if outline.model != nil { outline.model = nil; outlineMesh = nil; outlineShell = [] }
            return
        }
        let offset = Float(grade.outlineWidth)
        outlineShell = TubeMeshPacker.shell(packed, offset: offset, brightness: 1.0)
        outlineTint = Self.outlineColour
        if outlineMesh == nil || outlineMesh?.vertexCapacity != outlineShell.count {
            do {
                let built = try LowLevelTubeMesh(template: mesh)
                outlineMesh = built
                outline.model = ModelComponent(mesh: try built.resource(),
                                            materials: [outlineMaterial(tint: outlineTint)])
            } catch {
                print("PHONEFOLD: outline build FAILED: \(error)")
                return
            }
        }
        outlineIndices = mesh.indices
        refreshOutline()
    }

    /// Re-cull the halo for the current view direction.
    ///
    /// Called both when a frame arrives and when the camera moves. The cost is one dot
    /// product per triangle over a mesh that is already in cache.
    private func refreshOutline() {
        guard let outlineMesh, !outlineShell.isEmpty, !outlineIndices.isEmpty else { return }
        let visible = TubeMeshPacker.farFacing(vertices: outlineShell, indices: outlineIndices,
                                               eye: eyeInMeshSpace())
        guard !visible.isEmpty else { return }
        do {
            try outlineMesh.update(vertices: outlineShell, indices: visible)
            if var component = outline.model {
                component.materials = [outlineMaterial(tint: outlineTint)]
                outline.model = component
            }
        } catch {
            print("PHONEFOLD: outline update FAILED: \(error)")
        }
    }

    /// Linear to sRGB, the encode RealityKit's stock materials expect.
    private static func encodeSRGB(_ c: Float) -> CGFloat {
        let v = Swift.min(Swift.max(c, 0), 1)
        return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    /// Unlit, because the halo is meant to read as emission: shading it would darken it
    /// exactly where the tube curves away, which is where the glow should be strongest.
    ///
    /// Front faces are culled so only the far wall of the shell survives, which leaves a rim
    /// around the silhouette instead of a haze laid over the tube. Unlit because the halo is
    /// meant to be emission: shading it would make it darker exactly where the tube curves
    /// away, which is where the glow should be strongest.
    /// A near-black outline, in the manner of a ray-traced PyMOL cartoon.
    ///
    /// It was a bright halo first, on the theory that a concert wants glow. Against ribbons
    /// it read as a pink fringe drawn around everything. Dark is what the convention actually
    /// is, and it earns its place: on the near-black ground the outline is invisible in open
    /// space and only appears where one element passes in front of another, which is exactly
    /// where the eye needs the separation. It also hides the fine teeth on its own edge,
    /// which are unavoidable while the outline is selected a whole triangle at a time.
    private static let outlineColour = SIMD3<Float>(0.020, 0.018, 0.045)

    private func outlineMaterial(tint: SIMD3<Float>) -> RealityKit.Material {
        let encode = Self.encodeSRGB
        var material = UnlitMaterial()
        material.color = .init(tint: .init(red: encode(tint.x), green: encode(tint.y),
                                           blue: encode(tint.z), alpha: 1))
        // Opaque, not transparent.
        //
        // A transparent material in RealityKit is drawn in a later pass without writing
        // depth, so the outline shell - which sits *behind* the protein, being the far-facing
        // half - was composited over whatever had already been drawn there. On screen that
        // reads exactly as Marc described it: a see-through patch at the bottom of each helix
        // turn, where the far wall of the shell showed through the ribbon in front of it.
        //
        // It was transparent for a reason that no longer holds: before the far-facing
        // triangles were selected on the CPU, an opaque shell covered the whole protein. Now
        // that only the far half is drawn, depth testing puts it behind the tube by itself.
        return material
    }

    /// The protein's one material.
    ///
    /// **Built by `FoldRender`, not here.** It used to be constructed in this file, which was
    /// fine while the only renderer was this one. Phase 4 exports video offscreen, and PLAN's
    /// gate asks that the exported film and live playback be visually identical - which two
    /// constructions of the same material cannot guarantee, because they drift.
    private func proteinMaterial(options: ColourOptions) -> RealityKit.Material {
        rampMode = colourMode
        return ProteinMaterial.material(mode: colourMode, options: options)
    }

    /// Kept for device testing: the custom shader path, which may well work on real hardware
    /// where the Simulator's constant buffer limit does not apply. Opt in with
    /// PHONEFOLD_CUSTOM_SHADER=1.
    /// **Not available on visionOS at all.** RealityKit there has no `CustomMaterial`: custom
    /// Metal surface shaders are not permitted, which is a platform decision rather than an
    /// omission. The default path does not use it anyway - the protein is one part with a ramp
    /// texture - so visionOS simply takes the fallback that every other platform takes unless
    /// PHONEFOLD_CUSTOM_SHADER is set.
    private func tubeMaterial() -> RealityKit.Material {
        if let material { return material }
        var made: RealityKit.Material
        #if os(visionOS)
        var unlit = UnlitMaterial(color: .white)
        unlit.faceCulling = .none
        made = unlit
        #else
        do {
            let library = try MTLCreateSystemDefaultDevice()
                .flatMap { try $0.makeDefaultLibrary(bundle: .main) }
            if let library {
                let surface = CustomMaterial.SurfaceShader(named: "phonefoldTubeSurface",
                                                           in: library)
                // Unlit: the *lit* model's fsSurfacePbr program exceeds the Simulator's
                // constant buffer limit (16 against 14) and its pipeline silently fails to
                // compile, leaving the mesh present and invisible. The shader does its own
                // lighting instead.
                var custom = try CustomMaterial(surfaceShader: surface,
                                                lightingModel: .unlit)
                custom.faceCulling = .none
                made = custom
            } else {
                var unlit = UnlitMaterial(color: .white)
                unlit.faceCulling = .none
                made = unlit
            }
        } catch {
            print("custom material unavailable, falling back: \(error)")
            var unlit = UnlitMaterial(color: .white)
            unlit.faceCulling = .none
            made = unlit
        }
        #endif
        material = made
        return made
    }
}
