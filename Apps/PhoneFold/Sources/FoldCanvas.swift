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
    let mesh: TubeMesh?
    let flashes: [FlashInstance]
    let colourMode: ColourMode
    let residues: [AminoAcid]
    let residueCount: Int
    /// The frame's own per-residue confidence. Passing zeros here colours a fully confident
    /// protein as though it had no confidence at all, and the readout above it still reads
    /// 91: the number and the picture would come from different places.
    let residueConfidence: [Float]

    @State private var stage = StageContent()
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        RealityView { content in
            content.add(stage.root)
        } update: { _ in
            stage.apply(mesh: mesh, flashes: flashes, colourMode: colourMode,
                        residues: residues, residueCount: residueCount,
                        residueConfidence: residueConfidence)
        }
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
        .onAppear { stage.startClock() }
        .onDisappear { stage.stopClock() }
    }
}

/// Owns the RealityKit entities, the mesh buffer and the camera across updates.
@MainActor
@Observable
final class StageContent {
    let root = Entity()
    var camera = StageCamera()

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
    private var clock: Task<Void, Never>?
    private var lastBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?

    init() {
        root.addChild(protein)
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

    private func applyProteinTransform() {
        guard let bounds = lastBounds else { return }
        let extent = simd_length(bounds.maximum - bounds.minimum)
        let scale = extent > 0.001 ? 1.15 / extent : 1
        let centre = (bounds.maximum + bounds.minimum) * 0.5
        // Inverse of the camera's orbit, so dragging left turns the protein left.
        let rotation = simd_quatf(angle: -camera.pitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: -camera.yaw, axis: SIMD3<Float>(0, 1, 0))
        protein.transform = Transform(scale: SIMD3<Float>(repeating: scale),
                                      rotation: rotation,
                                      translation: rotation.act(-(centre + camera.target) * scale))
    }

    func apply(mesh: TubeMesh?, flashes: [FlashInstance], colourMode: ColourMode,
               residues: [AminoAcid], residueCount: Int, residueConfidence: [Float]) {
        guard let mesh, !mesh.vertices.isEmpty else { return }

        let options = ColourOptions(residueCount: residueCount, residues: residues)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: residueConfidence,
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
        do {
            try tubeMesh?.update(vertices: packed, buckets: buckets)
            // One material per colour bucket. Reassigned each frame because the colours move
            // with the fold; SimpleMaterial is a value type and this is not an allocation of
            // any consequence beside the geometry.
            protein.model?.materials = materials(for: buckets)
        } catch {
            print("PHONEFOLD: vertex update FAILED: \(error)")
        }

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
