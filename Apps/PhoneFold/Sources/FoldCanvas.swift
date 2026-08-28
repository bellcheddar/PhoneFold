import SwiftUI
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
    @State private var orbit: Float = 0
    @State private var dragOrbit: Float = 0
    @State private var dragPitch: Float = 0

    var body: some View {
        RealityView { content in
            content.add(stage.root)
        } update: { _ in
            stage.apply(mesh: mesh, flashes: flashes, colourMode: colourMode,
                        residues: residues, residueCount: residueCount,
                        residueConfidence: residueConfidence,
                        yaw: orbit + dragOrbit, pitch: dragPitch)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOrbit = Float(value.translation.width) * 0.006
                    dragPitch = Float(value.translation.height) * 0.006
                }
        )
        .onAppear { startOrbit() }
    }

    /// Slow cinematic auto-orbit, per PLAN.md. Drag overrides it immediately because the
    /// drag offset is simply added.
    private func startOrbit() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                orbit += 0.0035
            }
        }
    }
}

/// Owns the RealityKit entities and the mesh buffer across updates.
@MainActor
@Observable
final class StageContent {
    let root = Entity()
    private let protein = ModelEntity()
    private let flashRoot = Entity()
    private var tubeMesh: LowLevelTubeMesh?
    private var capacity = 0

    private var material: RealityKit.Material?

    init() {
        root.addChild(protein)
        root.addChild(flashRoot)

        // An explicit camera, rather than relying on RealityView's default framing. Without
        // one the protein renders correctly but tiny, because the default camera sits far
        // enough back to frame a room-scale scene.
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: 0.01, far: 100,
                                                         fieldOfViewInDegrees: 42))
        camera.position = SIMD3<Float>(0, 0, 1.5)
        root.addChild(camera)
    }

    /// The custom surface shader, loaded once. Falls back to an unlit white material if the
    /// Metal library is missing, so a shader problem shows as a grey protein rather than an
    /// empty stage.
    private func tubeMaterial() -> RealityKit.Material {
        if let material { return material }
        var made: RealityKit.Material
        do {
            let library = try MTLCreateSystemDefaultDevice()
                .flatMap { try $0.makeDefaultLibrary(bundle: .main) }
            if let library {
                let surface = CustomMaterial.SurfaceShader(named: "phonefoldTubeSurface",
                                                           in: library)
                var custom = try CustomMaterial(surfaceShader: surface,
                                                lightingModel: .lit)
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

    func apply(mesh: TubeMesh?, flashes: [FlashInstance], colourMode: ColourMode,
               residues: [AminoAcid], residueCount: Int, residueConfidence: [Float],
               yaw: Float, pitch: Float) {
        guard let mesh, !mesh.vertices.isEmpty else { return }

        let options = ColourOptions(residueCount: residueCount, residues: residues)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: residueConfidence,
                                         mode: colourMode, options: options)

        // Allocate once per topology. Vertex count only changes when the protein does.
        if tubeMesh == nil || capacity != packed.count {
            tubeMesh = try? LowLevelTubeMesh(template: mesh)
            capacity = packed.count
            if let resource = try? tubeMesh?.resource() {
                protein.model = ModelComponent(mesh: resource, materials: [tubeMaterial()])
            }
        }
        try? tubeMesh?.update(vertices: packed)

        // Normalise scale so any protein fills the stage: 20 A across or 300, the fold is
        // the subject and the framing should not depend on its size.
        if let bounds = TubeMeshPacker.bounds(packed) {
            let extent = simd_length(bounds.maximum - bounds.minimum)
            // Fill most of the stage whatever the protein's size: 20 residues or 300, the
            // fold is the subject and the framing should not depend on how big it is.
            let scale = extent > 0.001 ? 1.15 / extent : 1
            let centre = (bounds.maximum + bounds.minimum) * 0.5
            protein.transform = Transform(
                scale: SIMD3<Float>(repeating: scale),
                rotation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                    * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0)),
                translation: -centre * scale)
        }
    }
}
