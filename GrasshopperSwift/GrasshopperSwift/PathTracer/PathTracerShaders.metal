//
//  PathTracerShaders.metal
//
//  Progressive Monte Carlo path tracer for the "Ultra Realistic" render mode.
//  Traces against a single flattened `primitive_acceleration_structure` built
//  by PathTracerScene.swift. One dispatch of `pathTraceKernel` adds one more
//  sample per pixel to a running-average accumulation texture; `resolveKernel`
//  tonemaps that texture to the drawable every frame.
//
//  Shading is a multi-lobe stochastic Principled-BSDF-style model (diffuse,
//  sheen, GGX specular — isotropic or anisotropic, a thin clearcoat lobe, and
//  a dielectric transmission/glass lobe using exact Fresnel equations), plus
//  homogeneous-medium random-walk subsurface scattering and volumetrics
//  (Henyey-Greenstein phase function, free-flight/Beer-Lambert sampling),
//  light-tree-importance-sampled next-event-estimation (point lights and
//  emissive triangles) combined with BSDF sampling via power-heuristic MIS,
//  a per-pixel Welford-variance adaptive-sampling convergence gate, and a
//  luminance clamp on individual NEE samples to suppress fireflies from
//  low-roughness specular lobes times narrow-pdf light picks.
//  Published physically-based shading/rendering math throughout (Walter et
//  al. 2007, Disney's "Physically Based Shading" course notes, Novák et al.
//  2018 volumetric path tracing course notes, Bitterli-style power-weighted
//  light BVHs) — not lifted from any specific renderer's source.
//

#include <metal_stdlib>
#include <metal_atomic>
#include <metal_raytracing>
#include "PathTracerShaderTypes.h"

using namespace metal;
using namespace metal::raytracing;

// MARK: - RNG
// PCG-style hash (Jarzynski & Olano, "Hash Functions for GPU Rendering") —
// cheap, good enough decorrelation for a few million independent pixel streams.

inline uint pcgHash(uint state) {
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline float randFloat(thread uint &seed) {
    seed = seed * 747796405u + 2891336453u;
    return float(pcgHash(seed)) * (1.0f / 4294967295.0f);
}

inline float2 randFloat2(thread uint &seed) {
    return float2(randFloat(seed), randFloat(seed));
}

// MARK: - Sampling helpers

inline float3 orthonormalTangent(float3 n) {
    float3 up = fabs(n.z) < 0.999f ? float3(0, 0, 1) : float3(1, 0, 0);
    return normalize(cross(up, n));
}

inline float3 cosineSampleHemisphere(float3 n, thread uint &seed) {
    float2 u = randFloat2(seed);
    float r = sqrt(u.x);
    float theta = 2.0f * M_PI_F * u.y;
    float3 t = orthonormalTangent(n);
    float3 b = cross(n, t);
    float z = sqrt(max(0.0f, 1.0f - u.x));
    return normalize(t * (r * cos(theta)) + b * (r * sin(theta)) + n * z);
}

// Uniform sampling over a cone around `dir` with half-angle acos(cosThetaMax)
// — used to jitter shadow rays toward the sun for soft penumbras.
inline float3 sampleCone(float3 dir, float cosThetaMax, thread uint &seed) {
    float2 u = randFloat2(seed);
    float cosTheta = (1.0f - u.x) + u.x * cosThetaMax;
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float phi = 2.0f * M_PI_F * u.y;
    float3 t = orthonormalTangent(dir);
    float3 b = cross(dir, t);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + dir * cosTheta);
}

// GGX normal-distribution importance sampling (Walter et al. 2007), isotropic.
inline float3 sampleGGXHalfVector(float3 n, float alpha, thread uint &seed) {
    float2 u = randFloat2(seed);
    float phi = 2.0f * M_PI_F * u.x;
    float cosTheta = sqrt((1.0f - u.y) / (1.0f + (alpha * alpha - 1.0f) * u.y));
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float3 t = orthonormalTangent(n);
    float3 b = cross(n, t);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + n * cosTheta);
}

inline float smithG1(float nDotX, float alpha) {
    float a2 = alpha * alpha;
    return 2.0f * nDotX / (nDotX + sqrt(a2 + (1.0f - a2) * nDotX * nDotX));
}

inline float3 fresnelSchlick(float3 f0, float vDotH) {
    float m = clamp(1.0f - vDotH, 0.0f, 1.0f);
    float m2 = m * m;
    float m5 = m2 * m2 * m;
    return f0 + (float3(1.0f) - f0) * m5;
}

/// Exact dielectric Fresnel reflectance (not Schlick — Schlick is inaccurate
/// near grazing angles, which matters here for the reflect-vs-refract branch
/// decision on the transmission lobe). `eta` = n_incident / n_transmitted.
inline float fresnelDielectric(float cosThetaI, float eta) {
    float sinThetaT2 = eta * eta * max(0.0f, 1.0f - cosThetaI * cosThetaI);
    if (sinThetaT2 >= 1.0f) return 1.0f; // total internal reflection
    float cosThetaT = sqrt(max(0.0f, 1.0f - sinThetaT2));
    float rParl = (eta * cosThetaI - cosThetaT) / max(eta * cosThetaI + cosThetaT, 1e-6f);
    float rPerp = (cosThetaI - eta * cosThetaT) / max(cosThetaI + eta * cosThetaT, 1e-6f);
    return clamp(0.5f * (rParl * rParl + rPerp * rPerp), 0.0f, 1.0f);
}

inline float ggxD(float alpha, float nDotH) {
    float a2 = alpha * alpha;
    float denom = nDotH * nDotH * (a2 - 1.0f) + 1.0f;
    return a2 / max(M_PI_F * denom * denom, 1e-6f);
}

/// Analytic fit for the GGX BRDF's single-scatter directional albedo
/// Ess(roughness, nDotV) — i.e. the white-furnace-test reflectance of the
/// Smith-GGX lobe alone, with no LUT/texture (Karis 2013, "Real Shading in
/// Unreal Engine 4" course notes, mobile split-sum approximation; A+B with
/// F0=1 gives exactly this single-scatter albedo). A few ALU ops.
inline float ggxDirectionalAlbedo(float roughness, float nDotV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * nDotV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return clamp(ab.x + ab.y, 0.0f, 1.0f);
}

/// Kulla & Conty 2017 ("Revisiting Physically Based Shading at Imageworks")
/// style multi-scatter energy-compensation multiplier for the GGX specular
/// lobe. Single-scatter GGX only accounts for light leaving after exactly
/// one microfacet bounce; at high roughness a growing fraction instead
/// bounces 2+ times before escaping, and single-scatter evaluation simply
/// drops that energy — a furnace test (fully white/mirror environment)
/// comes out visibly darker than white, and rough metals/plastics read as
/// slightly too dark next to a photo reference. Rather than simulating the
/// extra bounces, this folds the missing energy `1 - Ess` back in
/// analytically as a multiplier on the existing single-scatter value —
/// exact for a furnace test, a cheap and standard approximation otherwise.
inline float3 ggxEnergyCompensation(float3 f0, float roughness, float nDotV) {
    float ess = max(ggxDirectionalAlbedo(roughness, nDotV), 1e-3f);
    return float3(1.0f) + f0 * (1.0f / ess - 1.0f);
}

/// Anisotropic Trowbridge-Reitz/GGX NDF, evaluated in the shading-point's
/// local tangent frame (x = tangent, y = bitangent, z = normal).
inline float ggxAnisoD(float3 hLocal, float ax, float ay) {
    float hx2 = (hLocal.x * hLocal.x) / (ax * ax);
    float hy2 = (hLocal.y * hLocal.y) / (ay * ay);
    float hz2 = hLocal.z * hLocal.z;
    float denom = hx2 + hy2 + hz2;
    return 1.0f / max(M_PI_F * ax * ay * denom * denom, 1e-8f);
}

/// Classic (non-VNDF) anisotropic GGX importance sampling via polar-CDF
/// inversion (Walter et al. 2007 / standard closed form).
inline float3 sampleAnisoGGXHalfVector(float3 n, float3 t, float3 b, float ax, float ay, thread uint &seed) {
    float2 u = randFloat2(seed);
    float phi = atan2(ay * sin(2.0f * M_PI_F * u.x), ax * cos(2.0f * M_PI_F * u.x));
    float cosPhi = cos(phi), sinPhi = sin(phi);
    float invAlpha2 = 1.0f / max((cosPhi * cosPhi) / (ax * ax) + (sinPhi * sinPhi) / (ay * ay), 1e-6f);
    float tanTheta2 = (u.y / max(1.0f - u.y, 1e-6f)) * invAlpha2;
    float cosTheta = 1.0f / sqrt(1.0f + tanTheta2);
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float3 hLocal = float3(sinTheta * cosPhi, sinTheta * sinPhi, cosTheta);
    return normalize(t * hLocal.x + b * hLocal.y + n * hLocal.z);
}

/// Stable per-triangle tangent derived from a mesh edge (no UV/tangent buffer
/// exists in this pipeline) — anisotropy direction follows mesh topology
/// rather than authored UVs; a documented simplification.
inline float3 triangleTangent(float3 v0, float3 v1, float3 n) {
    float3 edge = v1 - v0;
    float3 tangent = edge - n * dot(edge, n);
    float len = length(tangent);
    return len > 1e-6f ? tangent / len : orthonormalTangent(n);
}

inline float3 skyRadiance(float3 direction, constant PTSceneUniforms &scene) {
    float t = clamp(direction.y * 0.5f + 0.5f, 0.0f, 1.0f);
    return mix(scene.skyHorizon, scene.skyZenith, t);
}

inline float luminance(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Caps one next-event-estimation sample's contribution at `maxLuminance`,
/// rescaling toward black to preserve its hue rather than hard-clipping a
/// channel. NEE terms divide by a sampling pdf (light-tree selection pdf,
/// converted to solid angle); a low-roughness specular/clearcoat lobe
/// evaluated toward a narrow-pdf light pick can spike that division many
/// orders of magnitude above a typical sample — a single-pixel "firefly"
/// that Monte Carlo averaging alone takes a very long time to wash out.
/// Clamping the rare outlier tail here trades a small, bounded amount of
/// energy loss for much faster visual convergence; it leaves the vast
/// majority of (already well-behaved) samples — and therefore the
/// converged image — essentially untouched. `maxLuminance <= 0` disables
/// clamping.
inline float3 clampFireflyContribution(float3 c, float maxLuminance) {
    if (maxLuminance <= 0.0f) return c;
    float lum = luminance(c);
    return (lum > maxLuminance && lum > 1e-8f) ? c * (maxLuminance / lum) : c;
}

// MARK: - Henyey-Greenstein phase function (participating media)

inline float hgPhase(float cosTheta, float g) {
    float denom = 1.0f + g * g - 2.0f * g * cosTheta;
    return (1.0f - g * g) / max(4.0f * M_PI_F * pow(max(denom, 1e-6f), 1.5f), 1e-8f);
}

/// Closed-form HG importance sampling (Pharr/Jakob/Humphreys, PBRT §11).
inline float3 sampleHenyeyGreenstein(float3 d, float g, thread uint &seed) {
    float2 u = randFloat2(seed);
    float cosTheta;
    if (fabs(g) < 1e-3f) {
        cosTheta = 1.0f - 2.0f * u.x;
    } else {
        float sqrTerm = (1.0f - g * g) / (1.0f + g - 2.0f * g * u.x);
        cosTheta = -(1.0f + g * g - sqrTerm * sqrTerm) / max(2.0f * g, 1e-6f);
    }
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float phi = 2.0f * M_PI_F * u.y;
    float3 t = orthonormalTangent(d), b = cross(d, t);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + d * cosTheta);
}

// MARK: - Homogeneous participating medium

struct MediumCoeffs {
    float3 sigmaS;
    float3 sigmaA;
    float g;
};

/// Derives a subsurface-scattering random-walk medium from `Material3D`'s
/// subsurfaceColor/subsurfacePower/thickness fields. These were originally
/// Filament-only artistic knobs (not physical units), so this mapping is a
/// documented artistic choice, not a measured physical derivation.
inline MediumCoeffs mediumFromMaterial(PTMaterial material) {
    float meanFreePath = material.thickness / max(material.subsurfacePower, 0.01f);
    float sigmaT = 1.0f / max(meanFreePath, 1e-4f);
    MediumCoeffs result;
    result.sigmaS = sigmaT * material.subsurfaceColor;
    result.sigmaA = sigmaT * (float3(1.0f) - material.subsurfaceColor);
    result.g = 0.0f;
    return result;
}

// MARK: - BSDF

struct BSDFSample {
    float3 direction;
    float3 weight;    // f * cos / (lobe pdf * lobe-selection probability)
    float pdf;         // combined solid-angle pdf estimate, for MIS bookkeeping
    bool isSpecular;    // true for mirror-like lobes (low roughness, clearcoat, transmission)
};

inline float3 fresnelBaseReflectance(PTMaterial material) {
    float3 f0Dielectric = float3(0.04f * clamp(material.specular * 2.0f, 0.0f, 1.0f));
    if (material.transmission > 0.0f) {
        float f0FromIOR = pow((material.ior - 1.0f) / (material.ior + 1.0f), 2.0f);
        f0Dielectric = float3(f0FromIOR);
    }
    return mix(f0Dielectric, material.baseColor, material.metalness);
}

/// Direct-lighting BRDF evaluation for next-event-estimation (sun / light
/// tree). Sums diffuse + sheen + GGX specular + clearcoat analytically
/// (isotropic only — anisotropy is applied to the BSDF-*sampling* lobe only,
/// a documented simplification); the transmission lobe is deliberately
/// excluded here (renderers conventionally don't NEE through a refractive
/// interface — handled by BSDF sampling + MIS instead).
inline float3 evalDirectBRDF(PTMaterial material, float3 n, float3 viewDir, float3 lightDir) {
    float nDotL = dot(n, lightDir);
    float nDotV = dot(n, viewDir);
    if (nDotL <= 0.0f || nDotV <= 0.0f) return float3(0.0f);

    float3 h = normalize(viewDir + lightDir);
    float3 f0 = fresnelBaseReflectance(material);
    float alpha = max(material.roughness * material.roughness, 1e-3f);
    float nDotH = max(dot(n, h), 0.0f);

    float d = ggxD(alpha, nDotH);
    float g = smithG1(nDotV, alpha) * smithG1(nDotL, alpha);
    float3 fr = fresnelSchlick(f0, max(dot(viewDir, h), 0.0f));
    float3 specular = fr * (d * g / max(4.0f * nDotV * nDotL, 1e-4f)) * ggxEnergyCompensation(f0, material.roughness, nDotV);

    float3 diffuse = material.baseColor * (1.0f - material.metalness) * (1.0f - material.transmission) * (1.0f / M_PI_F);

    float sheenTerm = pow(clamp(1.0f - nDotH, 0.0f, 1.0f), max(material.sheenRoughness, 0.01f) * 10.0f);
    float3 sheen = material.sheenColor * sheenTerm * (1.0f - material.metalness);

    float ccAlpha = max(material.clearcoatRoughness * material.clearcoatRoughness, 1e-4f);
    float ccD = ggxD(ccAlpha, nDotH);
    float ccG = smithG1(nDotV, ccAlpha) * smithG1(nDotL, ccAlpha);
    float ccFr = 0.04f + 0.96f * pow(clamp(1.0f - max(dot(viewDir, h), 0.0f), 0.0f, 1.0f), 5.0f);
    float clearcoatTerm = material.clearcoat * ccFr * (ccD * ccG / max(4.0f * nDotV * nDotL, 1e-4f));

    return diffuse + specular + sheen + float3(clearcoatTerm);
}

/// Approximates the combined BSDF-sampling pdf at a NEE-chosen direction, for
/// the MIS power heuristic — mirrors `evalDirectBRDF`'s dominant lobes
/// (diffuse + specular) but doesn't replicate sheen/clearcoat/transmission's
/// small pdf contributions (a documented approximation: those lobes are
/// minor pdf contributors and the sheen/clearcoat probabilities aren't worth
/// the extra ALU here).
inline float bsdfPdf(PTMaterial material, float3 n, float3 viewDir, float3 lightDir) {
    float nDotL = dot(n, lightDir);
    if (nDotL <= 0.0f) return 0.0f;

    float3 f0 = fresnelBaseReflectance(material);
    float specLuma = max(f0.x, max(f0.y, f0.z));
    float wTransmission = material.transmission * (1.0f - material.metalness);
    float wSpecular = clamp(specLuma + material.metalness * 0.5f, 0.05f, 0.95f) * (1.0f - wTransmission);
    float wDiffuse = (1.0f - material.metalness) * (1.0f - wTransmission);
    float sum = max(wTransmission + wSpecular + wDiffuse, 1e-4f);
    wSpecular /= sum; wDiffuse /= sum;

    float diffusePdf = nDotL / M_PI_F;
    float3 h = normalize(viewDir + lightDir);
    float alpha = max(material.roughness * material.roughness, 1e-3f);
    float nDotH = max(dot(n, h), 0.0f);
    float vDotH = max(dot(viewDir, h), 1e-4f);
    float specPdf = ggxD(alpha, nDotH) * nDotH / (4.0f * vDotH);

    return wDiffuse * diffusePdf + wSpecular * specPdf;
}

/// Samples one outgoing bounce direction from the full multi-lobe Principled
/// BSDF (diffuse, sheen, specular — isotropic or anisotropic GGX, clearcoat,
/// dielectric transmission), or — for subsurface-family materials — a
/// diffuse-style entry/exit direction into/out of the interior random-walk
/// medium. One random draw picks a lobe; the returned weight is already
/// divided by that lobe's own directional pdf AND its selection probability
/// ("one-sample MIS over lobes" — the standard way to keep a stochastic
/// multi-lobe BSDF unbiased without every lobe needing to sum to <1 alone).
inline BSDFSample sampleBSDF(PTMaterial material, float3 n, float3 tangent, float3 viewDir, bool currentlyInMedium, thread uint &seed) {
    BSDFSample result;
    result.weight = float3(0.0f);
    result.pdf = 0.0f;
    result.isSpecular = false;

    if (material.isSubsurface != 0) {
        if (!currentlyInMedium) {
            float3 l = cosineSampleHemisphere(-n, seed);
            result.direction = l;
            result.weight = material.baseColor;
            result.pdf = max(dot(-n, l), 0.0f) / M_PI_F;
        } else {
            float3 l = cosineSampleHemisphere(n, seed);
            result.direction = l;
            result.weight = float3(1.0f);
            result.pdf = max(dot(n, l), 0.0f) / M_PI_F;
        }
        return result;
    }

    float3 f0 = fresnelBaseReflectance(material);
    float specLuma = max(f0.x, max(f0.y, f0.z));
    float wTransmission = material.transmission * (1.0f - material.metalness);
    float wSpecular = clamp(specLuma + material.metalness * 0.5f, 0.05f, 0.95f) * (1.0f - wTransmission);
    float wSheen = (1.0f - material.metalness) * (1.0f - wTransmission) * luminance(material.sheenColor) * 0.5f;
    float wClearcoat = material.clearcoat * 0.25f;
    float wDiffuse = (1.0f - material.metalness) * (1.0f - wTransmission);
    float sum = max(wTransmission + wSpecular + wSheen + wClearcoat + wDiffuse, 1e-4f);
    wTransmission /= sum; wSpecular /= sum; wSheen /= sum; wClearcoat /= sum; wDiffuse /= sum;

    float u = randFloat(seed);
    float3 b = cross(n, tangent);

    if (u < wDiffuse) {
        float3 l = cosineSampleHemisphere(n, seed);
        float nDotL = max(dot(n, l), 0.0f);
        float3 diffuseAlbedo = material.baseColor * (1.0f - material.metalness);
        result.direction = l;
        result.weight = diffuseAlbedo / max(wDiffuse, 1e-6f);
        result.pdf = (nDotL / M_PI_F) * wDiffuse;
        result.isSpecular = false;

    } else if (u < wDiffuse + wSheen) {
        float3 l = cosineSampleHemisphere(n, seed);
        float nDotL = max(dot(n, l), 0.0f);
        float pdfL = nDotL / M_PI_F;
        float3 h = normalize(viewDir + l);
        float nDotH = max(dot(n, h), 0.0f);
        float sheenTerm = pow(clamp(1.0f - nDotH, 0.0f, 1.0f), max(material.sheenRoughness, 0.01f) * 10.0f);
        float3 sheenBRDF = material.sheenColor * sheenTerm;
        result.direction = l;
        result.weight = (sheenBRDF * nDotL) / max(pdfL, 1e-6f) / max(wSheen, 1e-6f);
        result.pdf = pdfL * wSheen;
        result.isSpecular = false;

    } else if (u < wDiffuse + wSheen + wSpecular) {
        float alpha = max(material.roughness * material.roughness, 1e-3f);
        bool aniso = material.anisotropy > 0.02f;
        float ax = alpha, ay = alpha;
        float3 h;
        if (aniso) {
            float aspect = sqrt(max(1.0f - 0.9f * clamp(material.anisotropy, 0.0f, 1.0f), 0.01f));
            ax = max(alpha / aspect, 1e-3f);
            ay = max(alpha * aspect, 1e-3f);
            h = sampleAnisoGGXHalfVector(n, tangent, b, ax, ay, seed);
        } else {
            h = sampleGGXHalfVector(n, alpha, seed);
        }
        float3 l = reflect(-viewDir, h);
        result.direction = l;
        float nDotL = dot(n, l), nDotV = dot(n, viewDir);
        if (nDotL > 0.0f && nDotV > 0.0f) {
            float vDotH = max(dot(viewDir, h), 0.0f);
            float3 fr = fresnelSchlick(f0, vDotH);
            float gAlpha = aniso ? sqrt(ax * ay) : alpha;
            float gTerm = smithG1(nDotV, gAlpha) * smithG1(nDotL, gAlpha);
            float g1v = smithG1(nDotV, gAlpha);
            result.weight = fr * (gTerm / max(g1v, 1e-4f)) * ggxEnergyCompensation(f0, material.roughness, nDotV) / max(wSpecular, 1e-6f);
            float nDotH = max(dot(n, h), 0.0f);
            float dVal = aniso ? ggxAnisoD(float3(dot(h, tangent), dot(h, b), dot(h, n)), ax, ay) : ggxD(alpha, nDotH);
            result.pdf = (dVal * nDotH / max(4.0f * vDotH, 1e-4f)) * wSpecular;
            result.isSpecular = material.roughness < 0.05f;
        }

    } else if (u < wDiffuse + wSheen + wSpecular + wClearcoat) {
        float ccAlpha = max(material.clearcoatRoughness * material.clearcoatRoughness, 1e-4f);
        float3 h = sampleGGXHalfVector(n, ccAlpha, seed);
        float3 l = reflect(-viewDir, h);
        result.direction = l;
        float nDotL = dot(n, l), nDotV = dot(n, viewDir);
        if (nDotL > 0.0f && nDotV > 0.0f) {
            float vDotH = max(dot(viewDir, h), 0.0f);
            float fr = 0.04f + 0.96f * pow(clamp(1.0f - vDotH, 0.0f, 1.0f), 5.0f);
            float gTerm = smithG1(nDotV, ccAlpha) * smithG1(nDotL, ccAlpha);
            float g1v = smithG1(nDotV, ccAlpha);
            result.weight = float3(fr * (gTerm / max(g1v, 1e-4f))) / max(wClearcoat, 1e-6f);
            float nDotH = max(dot(n, h), 0.0f);
            result.pdf = (ggxD(ccAlpha, nDotH) * nDotH / max(4.0f * vDotH, 1e-4f)) * wClearcoat;
            result.isSpecular = true;
        }

    } else {
        // Dielectric transmission (glass/liquid) — exact Fresnel reflect/refract.
        float cosThetaI = dot(n, viewDir);
        bool entering = cosThetaI > 0.0f;
        float3 nf = entering ? n : -n;
        float absCosI = fabs(cosThetaI);
        float eta = entering ? (1.0f / material.ior) : material.ior; // n_incident / n_transmitted
        float fr = fresnelDielectric(absCosI, eta);
        float alpha = max(material.roughness * material.roughness, 1e-3f);

        if (randFloat(seed) < fr) {
            float3 h = sampleGGXHalfVector(nf, alpha, seed);
            result.direction = reflect(-viewDir, h);
            result.weight = float3(1.0f) / max(wTransmission, 1e-6f);
            result.isSpecular = material.roughness < 0.05f;
        } else {
            float3 refracted = refract(-viewDir, nf, eta);
            if (length_squared(refracted) < 1e-8f) {
                float3 h = sampleGGXHalfVector(nf, alpha, seed);
                result.direction = reflect(-viewDir, h);
            } else {
                result.direction = normalize(refracted);
            }
            result.weight = float3(1.0f) / max(1.0f - fr, 1e-6f) / max(wTransmission, 1e-6f);
            result.isSpecular = material.roughness < 0.05f;
        }
        result.pdf = wTransmission;
    }

    return result;
}

// MARK: - Light tree (power-weighted importance sampling for many lights)

struct LightPick {
    uint lightRefIndex;
    float pdf;
    bool valid;
};

inline float3 barycentricSample(thread uint &seed) {
    float2 u = randFloat2(seed);
    float su0 = sqrt(u.x);
    float b0 = 1.0f - su0;
    float b1 = u.y * su0;
    return float3(b0, b1, 1.0f - b0 - b1);
}

inline float powerHeuristic(float pdfA, float pdfB) {
    float a2 = pdfA * pdfA, b2 = pdfB * pdfB;
    float denom = a2 + b2;
    return denom > 0.0f ? a2 / denom : 0.0f;
}

/// Stochastically descends the power-weighted light BVH, at each internal
/// node picking a child with probability proportional to power/distance^2
/// from `shadingPoint` — real light importance sampling, not the full
/// Bitterli/Moana cone-culling light tree. Root is the last node in the
/// (bottom-up-built) node array.
inline LightPick pickLightFromTree(constant PTSceneUniforms &scene, device const PTLightTreeNode *nodes, float3 shadingPoint, thread uint &seed) {
    LightPick pick; pick.lightRefIndex = 0; pick.pdf = 0.0f; pick.valid = false;
    if (scene.lightTreeNodeCount == 0) return pick;

    uint nodeIdx = scene.lightTreeNodeCount - 1;
    float pdf = 1.0f;
    while (true) {
        PTLightTreeNode node = nodes[nodeIdx];
        if (node.isLeaf) {
            pick.lightRefIndex = node.lightRefIndex;
            pick.pdf = pdf;
            pick.valid = true;
            return pick;
        }
        PTLightTreeNode left = nodes[node.leftChild];
        PTLightTreeNode right = nodes[node.rightChild];
        float3 lc = (left.boundsMin + left.boundsMax) * 0.5f;
        float3 rc = (right.boundsMin + right.boundsMax) * 0.5f;
        float lp = left.power.x + left.power.y + left.power.z;
        float rp = right.power.x + right.power.y + right.power.z;
        float wL = lp / max(length_squared(shadingPoint - lc), 1e-4f);
        float wR = rp / max(length_squared(shadingPoint - rc), 1e-4f);
        float total = wL + wR;
        float pL = total > 0.0f ? wL / total : 0.5f;
        if (randFloat(seed) < pL) {
            nodeIdx = node.leftChild;
            pdf *= max(pL, 1e-6f);
        } else {
            nodeIdx = node.rightChild;
            pdf *= max(1.0f - pL, 1e-6f);
        }
    }
}

/// The other half of MIS: given a *known* leaf (a BSDF-sampled ray landed on
/// this emissive triangle), replays the same importance heuristic bottom-up
/// via parent pointers to get the light tree's selection pdf for it from
/// `shadingPoint` — without this, a BSDF-sampled hit on an emissive triangle
/// couldn't be weighted against NEE's alternative pdf for that same light.
inline float lightTreePdfForLeaf(device const PTLightTreeNode *nodes, uint leafNodeIdx, float3 shadingPoint) {
    float pdf = 1.0f;
    uint node = leafNodeIdx;
    while (true) {
        uint parentIdx = nodes[node].parent;
        if (parentIdx == node) break; // root sentinel
        PTLightTreeNode parent = nodes[parentIdx];
        PTLightTreeNode left = nodes[parent.leftChild];
        PTLightTreeNode right = nodes[parent.rightChild];
        float3 lc = (left.boundsMin + left.boundsMax) * 0.5f;
        float3 rc = (right.boundsMin + right.boundsMax) * 0.5f;
        float lp = left.power.x + left.power.y + left.power.z;
        float rp = right.power.x + right.power.y + right.power.z;
        float wL = lp / max(length_squared(shadingPoint - lc), 1e-4f);
        float wR = rp / max(length_squared(shadingPoint - rc), 1e-4f);
        float total = wL + wR;
        float pL = total > 0.0f ? wL / total : 0.5f;
        bool isLeftChild = (parent.leftChild == node);
        pdf *= isLeftChild ? max(pL, 1e-6f) : max(1.0f - pL, 1e-6f);
        node = parentIdx;
    }
    return pdf;
}

// MARK: - Path tracing kernel

kernel void pathTraceKernel(
    texture2d<float, access::read_write>  accumTexture             [[texture(0)]],
    texture2d<float, access::read_write>  statsTexture              [[texture(1)]],
    texture2d<float, access::write>       positionTexture           [[texture(2)]],
    device const float3*                  vertexPositionsBuf        [[buffer(0)]],
    device const float3*                  vertexNormalsBuf          [[buffer(1)]],
    device const uint*                    triangleIndices           [[buffer(2)]],
    device const uint*                    triangleMaterial          [[buffer(3)]],
    device const PTMaterial*              materials                 [[buffer(4)]],
    constant PTCameraUniforms&            camera                    [[buffer(5)]],
    constant PTSceneUniforms&             scene                     [[buffer(6)]],
    device const PTPointLight*            pointLights               [[buffer(7)]],
    device const PTLightTreeNode*         lightTreeNodes            [[buffer(8)]],
    device const PTLightRef*              lightRefs                 [[buffer(9)]],
    device atomic_uint*                   activeSampleCounter       [[buffer(10)]],
    device const uint*                    trianglePrimIDToLightRecord [[buffer(11)]],
    device const uint*                    lightRecordToLeafNode     [[buffer(12)]],
    primitive_acceleration_structure      accelStructure            [[buffer(13)]],
    uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= camera.width || tid.y >= camera.height) return;

    float4 pixelStats = statsTexture.read(tid);
    // Frame 0's stats texture content is undefined GPU memory (same as
    // accumTexture — that one self-corrects via the *0 multiply in the
    // blend below, but a garbage `converged` flag here would wrongly gate
    // the very first sample), so only trust it from frame 1 onward.
    bool converged = (camera.frameIndex > 0) && (pixelStats.w > 0.5f);
    if (converged && camera.frameIndex >= scene.minSamplesBeforeCheck) {
        return;
    }

    atomic_fetch_add_explicit(activeSampleCounter, 1u, memory_order_relaxed);

    uint seed = (tid.x * 1973u + tid.y * 9277u + camera.frameIndex * 26699u) | 1u;

    float2 jitter = randFloat2(seed);
    float2 uv = (float2(tid) + jitter) / float2(float(camera.width), float(camera.height));
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y = -ndc.y;

    float3 rayDir = normalize(camera.forward
        + (ndc.x * camera.tanHalfFov * camera.aspect) * camera.right
        + (ndc.y * camera.tanHalfFov) * camera.up);

    ray r(camera.position, rayDir, 1e-3f, 1e6f);

    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);

    intersector<triangle_data> shadowIsect;
    shadowIsect.assume_geometry_type(geometry_type::triangle);
    shadowIsect.force_opacity(forced_opacity::opaque);
    shadowIsect.accept_any_intersection(true);

    float3 throughput = float3(1.0f);
    float3 radiance = float3(0.0f);
    float cosSunCone = cos(scene.sunAngularRadius);

    float prevBSDFPdf = 0.0f;
    bool prevSpecular = true;

    bool inMedium = false;
    float3 mediumSigmaS = float3(0.0f);
    float3 mediumSigmaA = float3(0.0f);
    float mediumG = 0.0f;

    for (uint bounce = 0; bounce < scene.maxBounces; bounce++) {
        auto hit = isect.intersect(r, accelStructure);

        // Primary-hit world position, for `reprojectKernel` to reproject
        // against on the next camera-move reset — see that kernel's doc
        // comment. Written every dispatch (not just frame 0) so it stays
        // fresh for whichever frame turns out to be the last one before the
        // next reset; harmless redundancy for the frames in between.
        if (bounce == 0) {
            if (hit.type != intersection_type::none) {
                positionTexture.write(float4(r.origin + r.direction * hit.distance, 1.0f), tid);
            } else {
                positionTexture.write(float4(0.0f, 0.0f, 0.0f, 0.0f), tid);
            }
        }

        // --- Homogeneous participating medium: global fog and/or the
        // interior of the object we're currently inside (SSS / glass). Only
        // one medium is considered active at a time (documented limitation:
        // no nested-medium stack — covers the vast majority of scenes), and
        // only between the ray's origin and an actual surface hit (fog
        // extending to an unbounded sky miss isn't handled in this pass).
        bool mediumActive = inMedium || (scene.globalVolume.enabled != 0);
        if (mediumActive && hit.type != intersection_type::none) {
            float3 sigmaS3, sigmaA3;
            float g;
            if (inMedium) {
                sigmaS3 = mediumSigmaS; sigmaA3 = mediumSigmaA; g = mediumG;
            } else {
                float heightScale = scene.globalVolume.heightFalloff > 0.0f
                    ? exp(-scene.globalVolume.heightFalloff * max(r.origin.y, 0.0f)) : 1.0f;
                sigmaS3 = scene.globalVolume.sigmaS * heightScale;
                sigmaA3 = scene.globalVolume.sigmaA * heightScale;
                g = scene.globalVolume.g;
            }
            float3 sigmaT3 = sigmaS3 + sigmaA3;
            // Monochromatic (average) extinction drives the free-flight
            // distance sample; the full RGB attenuation is then folded back
            // in as a ratio-tracking throughput correction — a standard
            // simplification that avoids per-channel/"hero wavelength"
            // spectral bookkeeping, exact for homogeneous media since there's
            // no majorant/heterogeneous delta-tracking complexity here.
            float sigmaTAvg = max((sigmaT3.x + sigmaT3.y + sigmaT3.z) / 3.0f, 1e-8f);
            float tFreeFlight = -log(max(1.0f - randFloat(seed), 1e-6f)) / sigmaTAvg;

            if (tFreeFlight < hit.distance) {
                float3 scatterPos = r.origin + r.direction * tFreeFlight;
                float pdfDist = sigmaTAvg * exp(-sigmaTAvg * tFreeFlight);
                float3 transmittance = exp(-sigmaT3 * tFreeFlight);
                throughput *= transmittance / max(pdfDist, 1e-8f);

                float3 albedo = sigmaS3 / max(sigmaT3, float3(1e-6f));
                float meanAlbedo = clamp((albedo.x + albedo.y + albedo.z) / 3.0f, 0.0f, 1.0f);

                // NEE at the scatter point, weighted by the phase function.
                {
                    float3 sunDir = normalize(scene.sunDirection);
                    float3 sampleDir = scene.sunAngularRadius > 0.0f ? sampleCone(sunDir, cosSunCone, seed) : sunDir;
                    ray shadowRay(scatterPos, sampleDir, 1e-3f, 1e6f);
                    auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                    if (shadowHit.type == intersection_type::none) {
                        float phase = hgPhase(dot(-r.direction, sampleDir), g);
                        radiance += clampFireflyContribution(throughput * albedo * phase * scene.sunColor * (4.0f * M_PI_F), scene.fireflyClamp);
                    }
                }
                if (scene.lightTreeNodeCount > 0) {
                    LightPick pick = pickLightFromTree(scene, lightTreeNodes, scatterPos, seed);
                    if (pick.valid && pick.pdf > 0.0f) {
                        PTLightRef lref = lightRefs[pick.lightRefIndex];
                        if (lref.isTriangle == 0) {
                            PTPointLight light = pointLights[lref.index];
                            float3 toLight = light.position - scatterPos;
                            float dist2 = length_squared(toLight);
                            float dist = sqrt(dist2);
                            float3 lightDir = toLight / max(dist, 1e-6f);
                            ray shadowRay(scatterPos, lightDir, 1e-3f, max(dist - 2e-3f, 1e-3f));
                            auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                            if (shadowHit.type == intersection_type::none) {
                                float phase = hgPhase(dot(-r.direction, lightDir), g);
                                float atten = 1.0f / max(dist2, 1e-4f);
                                radiance += clampFireflyContribution(throughput * albedo * phase * light.color * atten / max(pick.pdf, 1e-6f), scene.fireflyClamp);
                            }
                        } else {
                            uint primID = lref.index;
                            uint ti0 = triangleIndices[primID * 3 + 0], ti1 = triangleIndices[primID * 3 + 1], ti2 = triangleIndices[primID * 3 + 2];
                            float3 tv0 = vertexPositionsBuf[ti0], tv1 = vertexPositionsBuf[ti1], tv2 = vertexPositionsBuf[ti2];
                            float3 bary = barycentricSample(seed);
                            float3 lightPoint = tv0 * bary.x + tv1 * bary.y + tv2 * bary.z;
                            float3 gN = normalize(cross(tv1 - tv0, tv2 - tv0));
                            float area = 0.5f * length(cross(tv1 - tv0, tv2 - tv0));
                            float3 toLight = lightPoint - scatterPos;
                            float dist2 = length_squared(toLight);
                            float dist = sqrt(dist2);
                            float3 lightDir = toLight / max(dist, 1e-6f);
                            float cosLight = fabs(dot(lightDir, gN));
                            if (cosLight > 1e-5f && area > 1e-8f) {
                                ray shadowRay(scatterPos, lightDir, 1e-3f, max(dist - 2e-3f, 1e-3f));
                                auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                                if (shadowHit.type == intersection_type::none) {
                                    PTMaterial lightMat = materials[triangleMaterial[primID]];
                                    float lightPdfSA = pick.pdf * (dist2 / (area * cosLight));
                                    float phase = hgPhase(dot(-r.direction, lightDir), g);
                                    radiance += clampFireflyContribution(throughput * albedo * phase * lightMat.emission / max(lightPdfSA, 1e-6f), scene.fireflyClamp);
                                }
                            }
                        }
                    }
                }

                if (randFloat(seed) < meanAlbedo) {
                    throughput *= albedo / max(meanAlbedo, 1e-6f);
                    float3 newDir = sampleHenyeyGreenstein(r.direction, g, seed);
                    float cosTheta = dot(r.direction, newDir);
                    prevBSDFPdf = hgPhase(cosTheta, g);
                    prevSpecular = false;
                    r = ray(scatterPos, newDir, 1e-3f, 1e6f);
                    continue;
                } else {
                    break; // absorbed
                }
            } else {
                float3 transmittanceFull = exp(-sigmaT3 * hit.distance);
                throughput *= transmittanceFull;
            }
        }

        if (hit.type == intersection_type::none) {
            radiance += throughput * skyRadiance(r.direction, scene);
            break;
        }

        uint primID = hit.primitive_id;
        uint i0 = triangleIndices[primID * 3 + 0];
        uint i1 = triangleIndices[primID * 3 + 1];
        uint i2 = triangleIndices[primID * 3 + 2];
        float2 bary = hit.triangle_barycentric_coord;
        float3 nInterp = normalize(
            vertexNormalsBuf[i0] * (1.0f - bary.x - bary.y) +
            vertexNormalsBuf[i1] * bary.x +
            vertexNormalsBuf[i2] * bary.y);

        float3 hitPos = r.origin + r.direction * hit.distance;
        float3 viewDir = -r.direction;
        float3 n = dot(nInterp, viewDir) < 0.0f ? -nInterp : nInterp;
        float3 tangent = triangleTangent(vertexPositionsBuf[i0], vertexPositionsBuf[i1], n);

        PTMaterial material = materials[triangleMaterial[primID]];

        // Direct hit on an emissive triangle (area light) via BSDF sampling —
        // MIS-weighted against the light tree's alternative pdf for it.
        if (length_squared(material.emission) > 0.0f) {
            float misWeight = 1.0f;
            if (!prevSpecular && scene.lightTreeNodeCount > 0) {
                uint recordIdx = trianglePrimIDToLightRecord[primID];
                if (recordIdx != 0xFFFFFFFFu) {
                    uint leafIdx = lightRecordToLeafNode[recordIdx];
                    float treePdf = lightTreePdfForLeaf(lightTreeNodes, leafIdx, r.origin);
                    float area = 0.5f * length(cross(vertexPositionsBuf[i1] - vertexPositionsBuf[i0], vertexPositionsBuf[i2] - vertexPositionsBuf[i0]));
                    float cosLight = fabs(dot(viewDir, nInterp));
                    float lightPdfSA = (area > 1e-8f && cosLight > 1e-5f)
                        ? treePdf * (hit.distance * hit.distance / (area * cosLight)) : 0.0f;
                    misWeight = (lightPdfSA > 0.0f) ? powerHeuristic(prevBSDFPdf, lightPdfSA) : 1.0f;
                }
            }
            radiance += throughput * material.emission * misWeight;
        }

        // Sun — soft via cone-sampled shadow rays. Delta light: misWeight = 1.
        {
            float3 sunDir = normalize(scene.sunDirection);
            float3 sampleDir = scene.sunAngularRadius > 0.0f ? sampleCone(sunDir, cosSunCone, seed) : sunDir;
            float nDotL = dot(n, sampleDir);
            if (nDotL > 0.0f) {
                ray shadowRay(hitPos + n * 1e-4f, sampleDir, 1e-3f, 1e6f);
                auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                if (shadowHit.type == intersection_type::none) {
                    float3 brdf = evalDirectBRDF(material, n, viewDir, sampleDir);
                    radiance += clampFireflyContribution(throughput * brdf * scene.sunColor * nDotL, scene.fireflyClamp);
                }
            }
        }

        // Light tree — importance-picks one light (point or emissive
        // triangle) instead of looping every light at every shading point.
        if (scene.lightTreeNodeCount > 0) {
            LightPick pick = pickLightFromTree(scene, lightTreeNodes, hitPos, seed);
            if (pick.valid && pick.pdf > 0.0f) {
                PTLightRef lref = lightRefs[pick.lightRefIndex];
                if (lref.isTriangle == 0) {
                    PTPointLight light = pointLights[lref.index];
                    float3 toLight = light.position - hitPos;
                    float dist = length(toLight);
                    float3 lightDir = toLight / max(dist, 1e-6f);
                    float nDotL = dot(n, lightDir);
                    if (nDotL > 0.0f) {
                        ray shadowRay(hitPos + n * 1e-4f, lightDir, 1e-3f, max(dist - 2e-3f, 1e-3f));
                        auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                        if (shadowHit.type == intersection_type::none) {
                            float3 brdf = evalDirectBRDF(material, n, viewDir, lightDir);
                            float atten = 1.0f / max(dist * dist, 1e-4f);
                            radiance += clampFireflyContribution(throughput * brdf * light.color * nDotL * atten / max(pick.pdf, 1e-6f), scene.fireflyClamp);
                        }
                    }
                } else {
                    uint tPrim = lref.index;
                    uint ti0 = triangleIndices[tPrim * 3 + 0], ti1 = triangleIndices[tPrim * 3 + 1], ti2 = triangleIndices[tPrim * 3 + 2];
                    float3 tv0 = vertexPositionsBuf[ti0], tv1 = vertexPositionsBuf[ti1], tv2 = vertexPositionsBuf[ti2];
                    float3 tbary = barycentricSample(seed);
                    float3 lightPoint = tv0 * tbary.x + tv1 * tbary.y + tv2 * tbary.z;
                    float3 gN = normalize(cross(tv1 - tv0, tv2 - tv0));
                    float area = 0.5f * length(cross(tv1 - tv0, tv2 - tv0));
                    float3 toLight = lightPoint - hitPos;
                    float dist2 = length_squared(toLight);
                    float dist = sqrt(dist2);
                    float3 lightDir = toLight / max(dist, 1e-6f);
                    float nDotL = dot(n, lightDir);
                    float cosLight = fabs(dot(lightDir, gN));
                    if (nDotL > 0.0f && cosLight > 1e-5f && area > 1e-8f) {
                        ray shadowRay(hitPos + n * 1e-4f, lightDir, 1e-3f, max(dist - 2e-3f, 1e-3f));
                        auto shadowHit = shadowIsect.intersect(shadowRay, accelStructure);
                        if (shadowHit.type == intersection_type::none) {
                            PTMaterial lightMat = materials[triangleMaterial[tPrim]];
                            float lightPdfSA = pick.pdf * (dist2 / (area * cosLight));
                            float bsdfPdfDir = bsdfPdf(material, n, viewDir, lightDir);
                            float misW = powerHeuristic(lightPdfSA, bsdfPdfDir);
                            float3 brdf = evalDirectBRDF(material, n, viewDir, lightDir);
                            radiance += clampFireflyContribution(throughput * brdf * lightMat.emission * nDotL * misW / max(lightPdfSA, 1e-6f), scene.fireflyClamp);
                        }
                    }
                }
            }
        }

        BSDFSample bsdf = sampleBSDF(material, n, tangent, viewDir, inMedium, seed);
        if (length_squared(bsdf.weight) <= 0.0f) {
            break;
        }
        float nDotOut = dot(n, bsdf.direction);
        // Diffuse/sheen/specular/clearcoat lobes require the outgoing
        // direction on the same side as `n`; transmission/subsurface lobes
        // deliberately cross to the other side, so don't reject those here.
        bool crossesInterface = (material.transmission > 0.0f || material.isSubsurface != 0) && nDotOut < 0.0f;
        if (!crossesInterface && nDotOut <= 0.0f) {
            break;
        }
        throughput *= bsdf.weight * fabs(nDotOut);

        if (material.isSubsurface != 0) {
            inMedium = !inMedium;
            if (inMedium) {
                MediumCoeffs med = mediumFromMaterial(material);
                mediumSigmaS = med.sigmaS; mediumSigmaA = med.sigmaA; mediumG = med.g;
            }
        } else if (material.transmission > 0.0f && crossesInterface) {
            inMedium = !inMedium;
            if (inMedium) {
                // Clear glass by default (no separate absorption/scattering
                // fields on a plain transmissive material) — see
                // `mediumFromMaterial`'s doc comment for the SSS case.
                mediumSigmaS = float3(0.0f); mediumSigmaA = float3(0.0f); mediumG = 0.0f;
            }
        }

        prevBSDFPdf = bsdf.pdf;
        prevSpecular = bsdf.isSpecular;

        if (bounce > 3u) {
            float p = clamp(max(throughput.x, max(throughput.y, throughput.z)), 0.05f, 1.0f);
            if (randFloat(seed) > p) break;
            throughput /= p;
        }

        float3 originOffset = n * 1e-4f * (crossesInterface ? -1.0f : 1.0f);
        r = ray(hitPos + originOffset, bsdf.direction, 1e-3f, 1e6f);
    }

    // Welford online per-pixel luminance stats -> adaptive-sampling
    // convergence flag (see PathTracerHostView for the soft/hard sample-cap
    // gate that reads `activeSampleCounter` this feeds).
    float lum = luminance(radiance);
    float count = pixelStats.x + 1.0f;
    float delta = lum - pixelStats.y;
    float mean = pixelStats.y + delta / count;
    float delta2 = lum - mean;
    float m2 = pixelStats.z + delta * delta2;
    float variance = count > 1.0f ? m2 / (count - 1.0f) : 1e6f;
    float stdErrorOfMean = sqrt(variance / count);
    float relativeError = stdErrorOfMean / max(fabs(mean), 1e-4f);
    float convergedFlag = (count >= float(scene.minSamplesBeforeCheck) && relativeError < scene.targetRelativeError) ? 1.0f : 0.0f;
    statsTexture.write(float4(count, mean, m2, convergedFlag), tid);

    float4 prev = accumTexture.read(tid);
    // Per-pixel accumulated sample count rather than the global
    // `camera.frameIndex` — identical for any pixel that's been traced every
    // frame since the last reset (the common case), but lets
    // `reprojectKernel` seed a pixel with a nonzero starting count (from
    // reused history) independently of the frame-wide counter.
    float nF = pixelStats.x;
    float3 blended = (prev.xyz * nF + radiance) / (nF + 1.0f);
    accumTexture.write(float4(blended, 1.0f), tid);
}

// MARK: - Resolve: accumulation buffer -> tonemapped drawable

inline float3 acesFilmFit(float3 x) {
    float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

// MARK: - Reprojection (temporal history reuse across camera motion)

/// Runs once, right after a camera-only accumulation reset (see
/// `PathTracerHostView.resetAccumulation(reprojectable:)`), in place of
/// `clearStatsKernel`. Traces one un-jittered primary ray per pixel against
/// the *new* camera, reprojects that world-space hit point into the
/// *previous* frame's camera space, and — if the reprojected point survives
/// a depth-consistency check against the previous frame's own G-buffer —
/// seeds `accumTexture`/`statsTexture` from the history buffers instead of
/// restarting the pixel from zero samples. That seed is what lets the very
/// next `pathTraceKernel` dispatch pick up mid-convergence rather than
/// flashing back to pure noise on every drag/scroll/zoom tick.
///
/// This is the classic reverse-reprojection trick (Nehab et al. 2007-style),
/// simplified for a fully static scene: the only thing that ever moves here
/// is the camera, so there's no need for per-object motion vectors — a
/// world-space distance check against the history position buffer is enough
/// to reject disoccluded/edge/off-screen pixels and fall back to a fresh,
/// unbiased start for exactly those.
kernel void reprojectKernel(
    texture2d<float, access::read>  historyAccumTexture    [[texture(0)]],
    texture2d<float, access::read>  historyPositionTexture [[texture(1)]],
    texture2d<float, access::write> accumTexture            [[texture(2)]],
    texture2d<float, access::write> statsTexture             [[texture(3)]],
    constant PTCameraUniforms&      camera                   [[buffer(0)]],
    constant PTCameraUniforms&      historyCamera             [[buffer(1)]],
    primitive_acceleration_structure accelStructure           [[buffer(2)]],
    uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= camera.width || tid.y >= camera.height) return;

    float2 uv = (float2(tid) + 0.5f) / float2(float(camera.width), float(camera.height));
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    float3 rayDir = normalize(camera.forward
        + (ndc.x * camera.tanHalfFov * camera.aspect) * camera.right
        + (ndc.y * camera.tanHalfFov) * camera.up);

    ray r(camera.position, rayDir, 1e-3f, 1e6f);
    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    auto hit = isect.intersect(r, accelStructure);

    if (hit.type == intersection_type::none) {
        accumTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        statsTexture.write(float4(0.0f), tid);
        return;
    }

    float3 hitPos = r.origin + r.direction * hit.distance;
    float3 toPoint = hitPos - historyCamera.position;
    float viewZ = dot(toPoint, historyCamera.forward);
    if (viewZ <= 1e-4f) {
        accumTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        statsTexture.write(float4(0.0f), tid);
        return;
    }

    float ndcUsedX = dot(toPoint, historyCamera.right) / (viewZ * historyCamera.tanHalfFov * historyCamera.aspect);
    float ndcUsedY = dot(toPoint, historyCamera.up) / (viewZ * historyCamera.tanHalfFov);
    if (fabs(ndcUsedX) > 1.0f || fabs(ndcUsedY) > 1.0f) {
        accumTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        statsTexture.write(float4(0.0f), tid);
        return;
    }

    float2 historyUV = float2((ndcUsedX + 1.0f) * 0.5f, (-ndcUsedY + 1.0f) * 0.5f);
    uint2 historyTexel = uint2(
        min(uint(historyUV.x * float(historyCamera.width)), historyCamera.width - 1u),
        min(uint(historyUV.y * float(historyCamera.height)), historyCamera.height - 1u));

    float4 historyPos4 = historyPositionTexture.read(historyTexel);
    // ~2% of depth — tight enough to reject a reprojection that landed on a
    // different surface (silhouette edges, thin geometry) while tolerating
    // ordinary floating-point drift for a genuinely-the-same point.
    float distThreshold = max(viewZ * 0.02f, 1e-3f);
    if (historyPos4.w < 0.5f || length(historyPos4.xyz - hitPos) > distThreshold) {
        accumTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        statsTexture.write(float4(0.0f), tid);
        return;
    }

    float3 historyColor = historyAccumTexture.read(historyTexel).xyz;
    // Capped, not the history pixel's full sample count: keeps any ghosting
    // from view-dependent lobes (specular highlights shift with the camera
    // even though the surface didn't move) short-lived, since fresh samples
    // still make up at least 1/9th of the very next blended frame — while
    // still killing the "back to pure noise" pop on every drag/scroll tick.
    const float kHistorySampleCap = 8.0f;
    accumTexture.write(float4(historyColor, 1.0f), tid);
    statsTexture.write(float4(kHistorySampleCap, luminance(historyColor), 0.0f, 0.0f), tid);
}

/// Zeroes the per-pixel Welford stats texture — dispatched whenever
/// `PathTracerHostView.resetAccumulation()` fires and *isn't* immediately
/// followed by a `reprojectKernel` pass (scene edits, resizes, or a camera
/// move with no usable history yet), since the running mean/variance/
/// convergence state is only meaningful against the current, static
/// accumulation and must not carry stale statistics across a reset the way
/// `accumTexture` incidentally can (that one self-corrects via its own
/// `frameIndex == 0` multiply-by-zero blend). When `reprojectKernel` does
/// run instead, it writes every pixel of `statsTexture` itself (either a
/// history-seeded value or an explicit zero), making this kernel redundant
/// for that frame.
kernel void clearStatsKernel(
    texture2d<float, access::write> statsTexture [[texture(0)]],
    uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= statsTexture.get_width() || tid.y >= statsTexture.get_height()) return;
    statsTexture.write(float4(0.0f, 0.0f, 0.0f, 0.0f), tid);
}

kernel void resolveKernel(
    texture2d<float, access::read>  accumTexture [[texture(0)]],
    texture2d<float, access::write> outTexture   [[texture(1)]],
    constant float&                 exposure     [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= outTexture.get_width() || tid.y >= outTexture.get_height()) return;
    float3 color = accumTexture.read(tid).xyz * exposure;
    float3 mapped = acesFilmFit(color);
    outTexture.write(float4(mapped, 1.0f), tid);
}
