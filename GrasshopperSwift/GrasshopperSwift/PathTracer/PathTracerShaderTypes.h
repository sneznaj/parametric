//
//  PathTracerShaderTypes.h
//
//  Shared between Swift (PathTracerScene.swift / PathTracerRenderer.swift, via
//  the app's Objective-C bridging header) and the Metal ray-tracing kernel
//  (PathTracerShaders.metal). This is the single source of truth for the GPU
//  buffer layout crossing that boundary — keep both sides in sync with it
//  rather than hand-duplicating field lists.
//

#ifndef PathTracerShaderTypes_h
#define PathTracerShaderTypes_h

#include <simd/simd.h>

struct PTCameraUniforms {
    vector_float3 position;
    vector_float3 forward;
    vector_float3 right;
    vector_float3 up;
    float tanHalfFov;
    float aspect;
    unsigned int frameIndex;
    unsigned int width;
    unsigned int height;
};

/// Full Principled-BSDF-style material. Fields beyond baseColor/roughness/
/// metalness/specular/clearcoat mirror `Material3D` in Models/Geometry.swift
/// one-for-one (see `PathTracerScene.materialIndex(for:)` for the mapping) —
/// several of these (sheenColor/sheenRoughness/anisotropy/subsurface*/
/// thickness) already existed on `Material3D` for Filament but were silently
/// dropped by the path tracer before this struct grew to carry them.
struct PTMaterial {
    vector_float3 baseColor;
    float roughness;
    float metalness;
    float specular;
    float clearcoat;
    float clearcoatRoughness;      // fixed low-alpha coat lobe roughness
    vector_float3 sheenColor;
    float sheenRoughness;
    float anisotropy;              // [0,1] stretch amount; direction follows mesh topology (no UV/tangent buffer)
    float transmission;            // dielectric transmission weight (glass/liquid), [0,1]
    float ior;                     // index of refraction, entering-medium side
    vector_float3 emission;        // emissionColor * emissionStrength, premultiplied like sunColor
    vector_float3 subsurfaceColor;
    float subsurfacePower;
    float thickness;
    unsigned int isSubsurface;     // 1 if Material3D.resolvedShadingFamily == .subsurface
};

struct PTPointLight {
    vector_float3 position;
    vector_float3 color;   // already premultiplied by intensity
};

/// Homogeneous participating medium — shared by the global fog volume and,
/// per-object, by subsurface-scattering / dielectric-transmission interiors
/// (the latter derived on the fly in the kernel via `mediumFromMaterial`,
/// not stored separately). See `PTVolumeConfig` in Models/Geometry.swift.
struct PTMediumUniforms {
    vector_float3 sigmaS;      // scattering coefficient
    vector_float3 sigmaA;      // absorption coefficient
    float g;                   // Henyey-Greenstein asymmetry, [-1, 1]
    float heightFalloff;
    unsigned int enabled;
};

struct PTSceneUniforms {
    vector_float3 sunDirection;    // points FROM a surface point TOWARD the sun
    vector_float3 sunColor;        // already premultiplied by intensity
    float sunAngularRadius;        // radians; stylized (not physical) size, for soft shadows
    vector_float3 skyZenith;
    vector_float3 skyHorizon;
    unsigned int pointLightCount;
    unsigned int maxBounces;
    struct PTMediumUniforms globalVolume;
    unsigned int lightTreeNodeCount;
    // Adaptive sampling (see resolveKernel/pathTraceKernel's per-pixel
    // Welford convergence check).
    float targetRelativeError;
    unsigned int minSamplesBeforeCheck;
    // Firefly suppression: caps any single next-event-estimation sample's
    // luminance (pre-exposure radiance units) before it's added into
    // `radiance` — see `clampFireflyContribution` in PathTracerShaders.metal.
    // A low-roughness specular lobe times a narrow-pdf light-tree pick's
    // 1/pdf can spike many orders of magnitude above a well-behaved sample;
    // this bounds that tail without measurably biasing the converged image.
    float fireflyClamp;
};

/// Power-weighted binary light BVH node, built CPU-side in
/// `PathTracerScene.buildLightTree` over point lights + emissive triangles.
/// Explicit child indices (not an implicit complete-tree layout) since the
/// light set is irregular in size and a plain top-down median split doesn't
/// produce a complete tree.
struct PTLightTreeNode {
    vector_float3 boundsMin;
    vector_float3 boundsMax;
    vector_float3 power;           // summed radiant power of this node's subtree
    unsigned int leftChild;
    unsigned int rightChild;
    unsigned int lightRefIndex;    // valid only when isLeaf == 1
    unsigned int isLeaf;
    unsigned int parent;           // self-index for the root (sentinel: parent == own index)
};

/// Resolves a light-tree leaf to an actual light: either an index into the
/// PTPointLight buffer, or a triangle (primitive id) whose material carries
/// nonzero emission.
struct PTLightRef {
    unsigned int isTriangle;    // 0 = point light, 1 = emissive triangle
    unsigned int index;         // point-light index, or triangle primitive id
    float power;                // precomputed scalar power/luminance, used at leaves
};

#endif /* PathTracerShaderTypes_h */
