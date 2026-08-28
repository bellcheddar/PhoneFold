#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Surface shader for the backbone tube.
///
/// RealityKit's stock materials ignore a per-vertex colour channel, so the mesh renders flat
/// grey without this. The colour is computed on the CPU during vertex packing, arrives in the
/// `.color` channel, and is read here as `geometry.color()`.
///
/// The raw scalars arrive split across uv0 and uv1, because the shader API exposes each as a
/// float2:
///   uv0 = (residue parameter, secondary structure confidence)
///   uv1 = (structure code, residue confidence)
///
/// Emission rises with structure confidence, which is what gives a forming helix its rim:
/// PLAN.md asks for structure to glow as it resolves rather than merely change hue.
[[visible]]
void phonefoldTubeSurface(realitykit::surface_parameters params)
{
    auto surface = params.surface();
    auto geometry = params.geometry();

    half3 base = half3(geometry.color().rgb);
    float structureConfidence = saturate(geometry.uv0().y);

    surface.set_base_color(base);
    surface.set_roughness(half(0.42));
    surface.set_metallic(half(0.0));
    surface.set_emissive_color(half3(base * half(0.30 + 0.70 * structureConfidence)));
    surface.set_opacity(half(1.0));
}
