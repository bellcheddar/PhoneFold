import SwiftUI
import CoreGraphics
import RealityKit
import Metal
import simd
import FoldCore
import FoldRender

/// The stage itself: the protein, drawn from the tube mesh.
///
/// RealityKit with `LowLevelMesh`, as PLAN.md Phase 2 requires, so the vertex buffer is
/// rewritten in place each frame rather than a new `MeshResource` being built. RealityKit is
/// also the visionOS path, which is why it wins over SceneKit here.
struct FoldCanvas: View {
    @ObservedObject var player: FoldPlayer
    @Binding var diagnostic: String

    @State private var stage = StageContent()
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        // No `update:` closure driving the mesh. Frames arrive through the player's
        // `onFrame` sink instead, so drawing does not depend on a SwiftUI re-evaluation and
        // the fold is not paced by layout.
        // No `update:` closure driving the mesh. Frames arrive through the player's
        // `onFrame` sink instead, so drawing does not depend on a SwiftUI re-evaluation and
        // the fold is not paced by layout.
        RealityView { content in
            content.add(stage.root)
        }
        // Over the stage and nothing else, and never in the way of a gesture.
        .auroraVignette(stage.grade)
        // The grade sits directly on the RealityView's output, before the gestures, so it
        // covers exactly the stage and nothing else. `onGeometryChange` rather than a
        // GeometryReader wrapper: the reader would relayout the view it wraps, and the
        // shader needs the size only to place its radial terms.
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Deltas, not the cumulative translation: using the total resets the
                    // rotation to zero on release and snaps the view back.
                    stage.camera.drag(deltaX: Float(value.translation.width - lastDrag.width),
                                      deltaY: Float(value.translation.height - lastDrag.height))
                    lastDrag = value.translation
                }
                .onEnded { _ in
                    lastDrag = .zero
                    stage.camera.endInteraction()
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { stage.camera.magnify(scale: Float($0.magnification)) }
                .onEnded { _ in stage.camera.endInteraction() }
        )
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
            stage.startClock()
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
    private var cachedMaterials: [RealityKit.Material] = []
    private var cachedColourKey: [SIMD3<Float>] = []
    /// The halo shell. A second entity so it can carry its own translucent material and
    /// its own culling without disturbing the tube's per-bucket parts.
    private let halo = ModelEntity()
    private var haloMesh: LowLevelTubeMesh?
    /// The shell of the last frame, kept so the halo can be re-culled when the protein turns
    /// without waiting for the next frame. The auto-orbit outlives playback, so a halo that
    /// only refreshed on new frames would freeze at the last frame's silhouette and then
    /// slide visibly out of register as the protein kept turning.
    private var haloShell: [RenderVertex] = []
    private var haloTint = SIMD3<Float>(0.5, 0.5, 0.6)
    private var haloIndices: [UInt32] = []
    private var clock: Task<Void, Never>?
    private var lastBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?

    init() {
        root.addChild(protein)
        // A child of the protein, not of the root. The camera's orbit and the framing scale
        // are applied to the protein's transform, so a halo parented to the root is drawn at
        // raw angstrom scale and unrotated: it filled the whole stage as a pale blob, which
        // looks like a broken material rather than a misplaced entity.
        protein.addChild(halo)
        // An explicit camera, rather than relying on RealityView's default framing. Without
        // one the protein renders correctly but tiny, because the default camera sits far
        // enough back to frame a room-scale scene.
        cameraEntity.components.set(PerspectiveCameraComponent(near: 0.01, far: 100,
                                                               fieldOfViewInDegrees: 42))
        root.addChild(cameraEntity)
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
        if grade.haloOpacity <= 0 || grade.haloWidth <= 0 {
            halo.model = nil
            haloMesh = nil
            haloShell = []
        } else {
            refreshHalo()
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
                self.camera.advance(deltaTime: Float(now.timeIntervalSince(last)))
                last = now
                self.applyCamera()
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
    private func applyCamera() {
        cameraEntity.transform = Transform(
            scale: .one,
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            translation: SIMD3<Float>(0, 0, camera.distance))
        applyProteinTransform()
    }

    /// Inverse of the camera's orbit, so dragging left turns the protein left.
    ///
    /// Shared with the halo's culling, which has to use exactly this rotation: derived
    /// separately, the two drift apart and the halo lights the wrong side of the protein.
    private func proteinRotation() -> simd_quatf {
        simd_quatf(angle: -camera.pitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: -camera.yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    private func applyProteinTransform() {
        guard let bounds = lastBounds else { return }
        let extent = simd_length(bounds.maximum - bounds.minimum)
        let scale = extent > 0.001 ? 1.15 / extent : 1
        let centre = (bounds.maximum + bounds.minimum) * 0.5
        let rotation = proteinRotation()
        protein.transform = Transform(scale: SIMD3<Float>(repeating: scale),
                                      rotation: rotation,
                                      translation: rotation.act(-(centre + camera.target) * scale))
        refreshHalo()
    }

    /// Reset when the protein changes, so the mesh is reallocated for the new topology.
    func reset() {
        tubeMesh = nil
        vertexCapacity = 0
        cachedMaterials = []
        cachedColourKey = []
    }

    func apply(frame: PreparedFrame, flashes: [FlashInstance]) {
        let mesh = frame.mesh
        guard !mesh.vertices.isEmpty else { return }

        let options = ColourOptions(residueCount: residueCount, residues: residues)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: frame.confidence,
                                         mode: colourMode, options: options)

        // Allocate once per topology. Vertex count only changes when the protein does.
        let buckets = ColourBuckets.split(vertices: packed, indices: mesh.indices)

        if tubeMesh == nil || vertexCapacity != packed.count {
            // Not `try?`: swallowing this hid a mesh that never got built, and the symptom
            // was an empty stage with no error anywhere.
            do {
                let built = try LowLevelTubeMesh(template: mesh)
                tubeMesh = built
                vertexCapacity = packed.count
                protein.model = ModelComponent(mesh: try built.resource(),
                                               materials: materials(for: buckets))
            } catch {
                print("PHONEFOLD: mesh build FAILED: \(error)")
                return
            }
        }
        if Diagnostics.isEnabled {
            lastDiagnostic = "tri=\(mesh.indices.count / 3) parts=\(buckets.parts.count) "
                + "idx=\(buckets.indices.count)/\(tubeMesh?.indexCapacity ?? 0) "
                + "v=\(packed.count)/\(vertexCapacity)"
        }
        do {
            try tubeMesh?.update(vertices: packed, buckets: buckets)
            // One material per colour bucket, read-modify-write.
            //
            // `protein.model?.materials = ...` looks equivalent and is not: `model` hands
            // back a *copy* of the component, so assigning through the optional chain
            // mutates the copy and never reaches the entity. The materials array therefore
            // stayed at whatever the first frame produced - a nearly uniform protein with
            // two or three buckets - and every later part whose materialIndex exceeded that
            // count was silently not drawn. The symptom was a backbone in clean-capped
            // pieces with gaps between them, with the mesh itself complete and correct.
            if var component = protein.model {
                component.materials = materials(for: buckets)
                protein.model = component
            }
        } catch {
            print("PHONEFOLD: vertex update FAILED: \(error)")
        }

        updateHalo(mesh: mesh, packed: packed, buckets: buckets)

        // Normalise so the framing does not depend on whether the protein is 20 residues
        // or 300, then apply the camera's orbit to it.
        if let bounds = TubeMeshPacker.bounds(packed) {
            lastBounds = bounds
            applyProteinTransform()
        }

        // Follow the action: ease toward where contacts are forming, in the protein's own
        // normalised space.
        if !flashes.isEmpty, let bounds = lastBounds {
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
    private func updateHalo(mesh: TubeMesh, packed: [RenderVertex],
                            buckets: ColourBuckets.Result) {
        guard grade.haloOpacity > 0, grade.haloWidth > 0 else {
            if halo.model != nil { halo.model = nil; haloMesh = nil; haloShell = [] }
            return
        }
        let offset = Float(grade.haloWidth) * TubeGeometry.Profile().coilRadius
        haloShell = TubeMeshPacker.shell(packed, offset: offset, brightness: 1.0)
        // Stock materials ignore the vertex colour channel - that is the whole reason the
        // tube is split into parts - so the halo takes its colour from the material, and the
        // material takes it from the frame's own buckets. The halo then follows the colour
        // mode without knowing anything about it.
        haloTint = meanColour(of: buckets)
        if haloMesh == nil || haloMesh?.vertexCapacity != haloShell.count {
            do {
                let built = try LowLevelTubeMesh(template: mesh)
                haloMesh = built
                halo.model = ModelComponent(mesh: try built.resource(),
                                            materials: [haloMaterial(tint: haloTint)])
            } catch {
                print("PHONEFOLD: halo build FAILED: \(error)")
                return
            }
        }
        haloIndices = mesh.indices
        refreshHalo()
    }

    /// Re-cull the halo for the current view direction.
    ///
    /// Called both when a frame arrives and when the camera moves. The cost is one dot
    /// product per triangle over a mesh that is already in cache.
    private func refreshHalo() {
        guard let haloMesh, !haloShell.isEmpty, !haloIndices.isEmpty else { return }
        // The camera sits on +Z looking toward the origin, and the orbit is applied to the
        // protein, so the direction toward the viewer in mesh space is the inverse of that
        // rotation applied to +Z.
        let rotation = proteinRotation()
        let viewAxis = rotation.inverse.act(SIMD3<Float>(0, 0, 1))
        let visible = TubeMeshPacker.farFacing(vertices: haloShell, indices: haloIndices,
                                               viewAxis: viewAxis)
        guard !visible.isEmpty else { return }
        do {
            try haloMesh.update(vertices: haloShell, indices: visible)
            if var component = halo.model {
                component.materials = [haloMaterial(tint: haloTint)]
                halo.model = component
            }
        } catch {
            print("PHONEFOLD: halo update FAILED: \(error)")
        }
    }

    /// The frame's average colour, weighted by how much of the tube each bucket covers.
    private func meanColour(of buckets: ColourBuckets.Result) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var weight: Float = 0
        for part in buckets.parts {
            let w = Float(part.count)
            total += part.colour * w
            weight += w
        }
        guard weight > 0 else { return SIMD3<Float>(0.5, 0.5, 0.6) }
        return total / weight
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
    private func haloMaterial(tint: SIMD3<Float>) -> RealityKit.Material {
        let encode = Self.encodeSRGB
        // Brightened toward white, because a halo the same colour as the tube reads as a
        // thicker tube rather than as light coming off one.
        let lifted = simd_clamp(tint * 1.9, SIMD3<Float>(repeating: 0),
                                SIMD3<Float>(repeating: 1))
        var material = UnlitMaterial()
        material.color = .init(tint: .init(red: encode(lifted.x), green: encode(lifted.y),
                                           blue: encode(lifted.z), alpha: 1))
        // Transparent now that only the far-facing half is drawn: it composites against the
        // background rather than over the tube, so it softens the rim into a glow instead of
        // washing the protein out, which is what the same setting did before the culling.
        material.blending = .transparent(
            opacity: .init(floatLiteral: Float(grade.haloOpacity)))
        return material
    }

    private func materials(for buckets: ColourBuckets.Result) -> [RealityKit.Material] {
        let key = buckets.parts.map(\.colour)
        if key.count == cachedColourKey.count,
           zip(key, cachedColourKey).allSatisfy({ simd_distance($0, $1) < 1e-4 }) {
            return cachedMaterials
        }
        let built = buildMaterials(for: buckets)
        cachedColourKey = key
        cachedMaterials = built
        return built
    }

    private func buildMaterials(for buckets: ColourBuckets.Result) -> [RealityKit.Material] {
        buckets.parts.map { part in
            // The bucket colour is linear; SimpleMaterial takes sRGB, so convert back.
            func encode(_ c: Float) -> CGFloat {
                let v = Swift.min(Swift.max(c, 0), 1)
                return CGFloat(v <= 0.0031308 ? v * 12.92
                               : 1.055 * pow(v, 1 / 2.4) - 0.055)
            }
            var material = SimpleMaterial(
                color: .init(red: encode(part.colour.x), green: encode(part.colour.y),
                             blue: encode(part.colour.z), alpha: 1),
                roughness: 0.42, isMetallic: false)
            material.faceCulling = .none
            return material
        }
    }

    /// Kept for device testing: the custom shader path, which may well work on real hardware
    /// where the Simulator's constant buffer limit does not apply. Opt in with
    /// PHONEFOLD_CUSTOM_SHADER=1.
    private func tubeMaterial() -> RealityKit.Material {
        if let material { return material }
        var made: RealityKit.Material
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
        material = made
        return made
    }
}
