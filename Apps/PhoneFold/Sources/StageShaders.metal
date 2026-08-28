#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Surface shader for the backbone tube.
///
/// **Unlit, and lights itself.** RealityKit's *lit* custom material fails to build a pipeline
/// on the Simulator: `fsSurfacePbr` reports "Constant buffer count [16] exceeds limit [14]"
/// and the technique never compiles, so the mesh is present, the material is assigned, and
/// absolutely nothing draws. Doing the shading here avoids the PBR program entirely and
/// gives exact control over the stage's look, which PLAN.md wants graded rather than
/// physically plausible.
///
/// Colour is computed on the CPU during vertex packing and arrives in the `.color` channel.
/// The scalars arrive split across uv0 and uv1, because the shader API exposes each as a
/// float2:
///   uv0 = (residue parameter, secondary structure confidence)
///   uv1 = (structure code, residue confidence)
[[visible]]
void phonefoldTubeSurface(realitykit::surface_parameters params)
{
    auto surface = params.surface();
    auto geometry = params.geometry();

    half3 base = half3(geometry.color().rgb);
    float structureConfidence = saturate(geometry.uv0().y);

    // A fixed key light from over the viewer's shoulder, plus a cool fill from below so the
    // underside of the tube never goes to black on a dark stage.
    float3 n = normalize(geometry.normal());
    const float3 keyDirection = normalize(float3(0.35, 0.55, 0.75));
    const float3 fillDirection = normalize(float3(-0.4, -0.6, 0.2));
    float key = saturate(dot(n, keyDirection));
    float fill = saturate(dot(n, fillDirection));

    // Rim light along the silhouette, which is what separates the tube from the background
    // and reads as the emissive glow of resolved structure.
    float3 viewDirection = normalize(params.geometry().view_direction());
    float rim = pow(1.0 - saturate(dot(n, viewDirection)), 2.5);

    half3 lit = base * half(0.30 + 0.85 * key + 0.22 * fill);
    half3 glow = base * half(rim * (0.35 + 0.65 * structureConfidence));

    surface.set_base_color(lit + glow);
    surface.set_opacity(half(1.0));
}
