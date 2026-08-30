// FilamentBridge.mm
// Objective-C++ implementation of the Filament C bridge.
// Wraps the Filament C++ API behind opaque C pointers for Swift interop.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "FilamentBridge.h"

// Filament C++ headers
#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/View.h>
#include <filament/Camera.h>
#include <filament/SwapChain.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/ColorGrading.h>
#include <filament/ToneMapper.h>
#include <filament/RenderableManager.h>
#include <filament/LightManager.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/IndexBuffer.h>
#include <filament/IndirectLight.h>
#include <filament/Skybox.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/MaterialEnums.h>

#include <backend/DriverEnums.h>

#include <utils/EntityManager.h>
#include <utils/Entity.h>

#include <math/vec3.h>
#include <math/vec4.h>
#include <math/mat4.h>
#include <math/quat.h>
#include <math/norm.h>
#include <math/scalar.h>

#include <filament/Viewport.h>

#include <image/Ktx1Bundle.h>
#include <ktxreader/Ktx1Reader.h>

#include <vector>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <fstream>

// Embedded compiled PBR material
#include "studio_pbr_filamat.h"
#include "studio_subsurface_filamat.h"

using namespace filament;
namespace fmath = filament::math;

// ---------------------------------------------------------------------------
// Static tone-mapper singletons — the ColorGrading builder takes a pointer to
// a ToneMapper. Filament's stock implementations are stateless, so a single
// instance is safe to share across all ColorGrading objects.
// ---------------------------------------------------------------------------

static LinearToneMapper      gLinearToneMapper;
static ACESLegacyToneMapper  gAcesLegacyToneMapper;
static FilmicToneMapper      gFilmicToneMapper;
static PBRNeutralToneMapper  gPbrNeutralToneMapper;
static AgxToneMapper         gAgxToneMapper;

static ToneMapper* toneMapperForInt(int mode) {
    switch (mode) {
        case 0: return &gLinearToneMapper;
        case 1: return &gAcesLegacyToneMapper;  // header's "ACES" maps to ACESLegacy
        case 2: return &gAcesLegacyToneMapper;  // "ACES_LEGACY"
        case 3: return &gFilmicToneMapper;
        case 4: return &gPbrNeutralToneMapper;
        case 5: return &gAgxToneMapper;
        default: return &gAcesLegacyToneMapper;
    }
}

// ---------------------------------------------------------------------------
// Helper: compute a tangent-frame quaternion from a normal vector.
// Filament's VertexAttribute::TANGENTS stores the tangent frame as a float4
// quaternion (qx, qy, qz, qw).
// ---------------------------------------------------------------------------
static fmath::float4 normalToTangentQuat(fmath::float3 n) {
    n = normalize(n);
    fmath::float3 from{0, 0, 1};
    fmath::float3 to = n;
    float d = dot(from, to);

    if (d > 0.9999f) {
        return fmath::float4{0, 0, 0, 1};
    }
    if (d < -0.9999f) {
        return fmath::float4{1, 0, 0, 0};
    }

    fmath::float3 axis = normalize(cross(from, to));
    float angle = acosf(d);
    float s = sinf(angle * 0.5f);
    float c = cosf(angle * 0.5f);
    return fmath::float4{axis.x * s, axis.y * s, axis.z * s, c};
}

// ---------------------------------------------------------------------------
// Helper: build a tangent-frame quaternion from an explicit (tangent, normal)
// pair, rather than deriving tangent implicitly from a single fixed
// reference vector as normalToTangentQuat does.
//
// normalToTangentQuat rotates a constant reference ({0,0,1}) to the vertex
// normal via the shortest arc. That construction is smooth almost
// everywhere, but — per the hairy ball theorem — cannot be continuous over
// every direction on a full sphere: it has an unavoidable singularity at
// whichever vertex normal exactly opposes the reference. Any shape whose
// normals sweep the full unit sphere (sphere, torus) or a full circle
// through that antipodal direction (cylinder/cone walls, tube-swept lines)
// hits that singularity at one exact vertex column, and the tangent frame
// spins wildly across the neighboring vertices — visible as a bright,
// spiky bump-mapping artifact sitting on otherwise-smooth geometry.
//
// The fix used by every analytically-parametrized "round" shape below is to
// pass in the real geometric tangent (d(position)/d(theta) of that shape's
// own sweep), which is continuous everywhere except the shape's actual
// poles (already a single degenerate vertex there, not a surface defect).
static fmath::float4 tangentFrameToQuat(fmath::float3 t, fmath::float3 n) {
    n = normalize(n);
    // Re-orthogonalize against the normal (Gram-Schmidt) so float error in
    // the caller's analytic tangent can't leave the frame non-orthonormal.
    t = t - n * dot(n, t);
    float tlen = length(t);
    if (tlen < 1e-6f) {
        // Only happens at a true parametrization pole (r == 0), where the
        // tangent direction is genuinely undefined but it's a single mesh
        // vertex, not a swept surface — any frame consistent with the
        // normal is fine there.
        return normalToTangentQuat(n);
    }
    t = t / tlen;
    fmath::float3 b = cross(n, t);

    // Columns [t | b | n] form a right-handed orthonormal rotation matrix;
    // convert to a quaternion (standard trace-based algorithm).
    float m00 = t.x, m01 = b.x, m02 = n.x;
    float m10 = t.y, m11 = b.y, m12 = n.y;
    float m20 = t.z, m21 = b.z, m22 = n.z;

    float trace = m00 + m11 + m22;
    float qx, qy, qz, qw;
    if (trace > 0.0f) {
        float s = sqrtf(trace + 1.0f) * 2.0f;
        qw = 0.25f * s;
        qx = (m21 - m12) / s;
        qy = (m02 - m20) / s;
        qz = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
        float s = sqrtf(1.0f + m00 - m11 - m22) * 2.0f;
        qw = (m21 - m12) / s;
        qx = 0.25f * s;
        qy = (m01 + m10) / s;
        qz = (m02 + m20) / s;
    } else if (m11 > m22) {
        float s = sqrtf(1.0f + m11 - m00 - m22) * 2.0f;
        qw = (m02 - m20) / s;
        qx = (m01 + m10) / s;
        qy = 0.25f * s;
        qz = (m12 + m21) / s;
    } else {
        float s = sqrtf(1.0f + m22 - m00 - m11) * 2.0f;
        qw = (m10 - m01) / s;
        qx = (m02 + m20) / s;
        qy = (m12 + m21) / s;
        qz = 0.25f * s;
    }
    return fmath::float4{qx, qy, qz, qw};
}

// ---------------------------------------------------------------------------
// Internal per-entity state. Holds the entity, its GPU buffers, the
// material instance, and a TransformManager instance index (for direct
// setTransform calls). Lights only have an entity + engine pointer.
// ---------------------------------------------------------------------------

struct FilamentEntity {
    utils::Entity entity;
    VertexBuffer* vb = nullptr;
    IndexBuffer*  ib = nullptr;
    MaterialInstance* materialInstance = nullptr;
    // True only when this entity privately owns materialInstance (the
    // null-material fallback path). Shapes normally share a cached instance
    // across many entities, so filament_removeEntity must not destroy those.
    bool ownsMaterialInstance = false;
    TransformManager::Instance transformInstance;  // invalid for lights
    Engine* engine = nullptr;
    bool isLight = false;
};

// ---------------------------------------------------------------------------
// Engine wrapper
// ---------------------------------------------------------------------------

struct FilamentEngine {
    Engine* engine = nullptr;
    Material* defaultMaterial = nullptr;
    Material* subsurfaceMaterial = nullptr;
    void* metalDevice = nullptr;
};

// ---------------------------------------------------------------------------
// Renderer wrapper. Filament's Renderer is opaque; we wrap it so we can stash
// clear options (Filament v1.72+ clear color lives on the renderer, not the
// view).
// ---------------------------------------------------------------------------

struct FilamentRenderer {
    Renderer* renderer = nullptr;
    LinearColorA clearColor = {0.0f, 0.0f, 0.0f, 1.0f};
    bool clearEnabled = true;
};

// ---------------------------------------------------------------------------
// ColorGrading wrapper. The header requires us to know the engine when
// destroying, so we hold both pointers.
// ---------------------------------------------------------------------------

struct FilamentColorGrading {
    ColorGrading* grading = nullptr;
    Engine* engine = nullptr;
};

FilamentEngine* filament_createEngine(void) {
    auto* fe = new FilamentEngine();

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        delete fe;
        return nullptr;
    }
    fe->metalDevice = (__bridge_retained void*)device;

    fe->engine = Engine::create(Engine::Backend::METAL);
    if (!fe->engine) {
        CFRelease(fe->metalDevice);
        delete fe;
        return nullptr;
    }

    // Load the default PBR material from embedded .filamat data.
    fe->defaultMaterial = Material::Builder()
        .package(studio_pbr_filamat, studio_pbr_filamat_len)
        .build(*fe->engine);

    // Subsurface-scattering material (wax/marble/translucent presets) — a
    // separate shading model from the default `lit` material above, so it
    // needs its own compiled Material.
    fe->subsurfaceMaterial = Material::Builder()
        .package(studio_subsurface_filamat, studio_subsurface_filamat_len)
        .build(*fe->engine);

    return fe;
}

void filament_destroyEngine(FilamentEngine* fe) {
    if (!fe) return;
    if (fe->engine) {
        // At this point all entities, views, scenes, etc. have been explicitly
        // destroyed by the caller. It is now safe to destroy the default material
        // and the engine itself.
        if (fe->defaultMaterial) {
            fe->engine->destroy(fe->defaultMaterial);
            fe->defaultMaterial = nullptr;
        }
        if (fe->subsurfaceMaterial) {
            fe->engine->destroy(fe->subsurfaceMaterial);
            fe->subsurfaceMaterial = nullptr;
        }
        Engine::destroy(&fe->engine);
        fe->engine = nullptr;
    }
    if (fe->metalDevice) {
        CFRelease(fe->metalDevice);
    }
    delete fe;
}

// ---------------------------------------------------------------------------
// Swap chain
// ---------------------------------------------------------------------------

FilamentSwapChain* filament_createSwapChain(FilamentEngine* fe,
                                            void* nativeWindow,
                                            uint64_t viewPtr) {
    if (!fe || !fe->engine) return nullptr;
    if (!nativeWindow) {
        NSLog(@"FilamentBridge: createSwapChain called with null nativeWindow");
        return nullptr;
    }
    (void)viewPtr;
    return (FilamentSwapChain*)fe->engine->createSwapChain(nativeWindow);
}

void filament_resizeSwapChain(FilamentEngine* /*fe*/,
                              FilamentSwapChain* /*swapChain*/,
                              int /*width*/, int /*height*/) {
    // Filament MetalSwapChain picks up resize from CAMetalLayer's drawableSize
    // automatically; no-op is correct.
}

void filament_destroySwapChain(FilamentEngine* fe, FilamentSwapChain* swapChain) {
    if (!fe || !fe->engine || !swapChain) return;
    auto* sc = (SwapChain*)swapChain;
    fe->engine->destroy(sc);
    // The Swift side is responsible for nilling its pointer.
}


// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

FilamentRenderer* filament_createRenderer(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    auto* fr = new FilamentRenderer();
    fr->renderer = fe->engine->createRenderer();
    return (FilamentRenderer*)fr;
}

void filament_rendererSetClearColor(FilamentRenderer* fr,
                                    float r, float g, float b, float a) {
    if (!fr) return;
    fr->clearColor = {r, g, b, a};
    Renderer::ClearOptions opts;
    opts.clearColor = {double(r), double(g), double(b), double(a)};
    opts.clear = fr->clearEnabled;
    opts.discard = true;
    fr->renderer->setClearOptions(opts);
}

void filament_rendererSetClear(FilamentRenderer* fr, bool enabled) {
    if (!fr) return;
    fr->clearEnabled = enabled;
    Renderer::ClearOptions opts;
    opts.clearColor = {double(fr->clearColor.r), double(fr->clearColor.g),
                       double(fr->clearColor.b), double(fr->clearColor.a)};
    opts.clear = enabled;
    opts.discard = true;
    fr->renderer->setClearOptions(opts);
}

bool filament_beginFrame(FilamentRenderer* fr, FilamentSwapChain* swapChain) {
    if (!fr || !fr->renderer || !swapChain) return false;
    // Re-apply clear options each frame in case anything mutated it externally.
    return fr->renderer->beginFrame((SwapChain*)swapChain);
}

void filament_render(FilamentRenderer* fr, FilamentView* view) {
    if (!fr || !fr->renderer || !view) return;
    fr->renderer->render((View*)view);
}

void filament_endFrame(FilamentRenderer* fr) {
    if (!fr || !fr->renderer) return;
    fr->renderer->endFrame();
}

void filament_destroyRenderer(FilamentEngine* fe, FilamentRenderer* fr) {
    if (!fe || !fe->engine || !fr) return;
    if (fr->renderer) {
        fe->engine->destroy(fr->renderer);
        fr->renderer = nullptr;
    }
    delete fr;
    // The Swift side is responsible for nilling its pointer.
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

FilamentScene* filament_createScene(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    return (FilamentScene*)fe->engine->createScene();
}

void filament_destroyScene(FilamentEngine* fe, FilamentScene* scene) {
    if (!fe || !fe->engine || !scene) return;
    auto* scn = (Scene*)scene;
    fe->engine->destroy(scn);
    // The Swift side is responsible for nilling its pointer.
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

FilamentCamera* filament_createCamera(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    auto& em = utils::EntityManager::get();
    utils::Entity cameraEntity = em.create();
    return (FilamentCamera*)fe->engine->createCamera(cameraEntity);
}

void filament_cameraLookAt(FilamentCamera* camera,
                           float eyeX, float eyeY, float eyeZ,
                           float centerX, float centerY, float centerZ,
                           float upX, float upY, float upZ) {
    if (!camera) return;
    auto* cam = (Camera*)camera;
    cam->lookAt({eyeX, eyeY, eyeZ}, {centerX, centerY, centerZ}, {upX, upY, upZ});
}

void filament_cameraSetPerspective(FilamentCamera* camera,
                                   float fovInDegrees,
                                   float aspect,
                                   float nearPlane,
                                   float farPlane) {
    if (!camera) return;
    auto* cam = (Camera*)camera;
    cam->setProjection(fovInDegrees, aspect, nearPlane, farPlane,
                       Camera::Fov::VERTICAL);
}

void filament_cameraOrbit(FilamentCamera* camera,
                          float theta, float phi, float radius,
                          float targetX, float targetY, float targetZ) {
    if (!camera) return;
    float eyeX = targetX + radius * cosf(phi) * cosf(theta);
    float eyeY = targetY + radius * sinf(phi);
    float eyeZ = targetZ + radius * cosf(phi) * sinf(theta);
    filament_cameraLookAt(camera, eyeX, eyeY, eyeZ, targetX, targetY, targetZ, 0, 1, 0);
}

void filament_cameraSetExposurePhysical(FilamentCamera* camera,
                                        float aperture,
                                        float shutterSpeed,
                                        float sensitivity) {
    if (!camera) return;
    ((Camera*)camera)->setExposure(aperture, shutterSpeed, sensitivity);
}

void filament_cameraSetExposureDirect(FilamentCamera* camera, float ev100) {
    if (!camera) return;
    // Camera::setExposure(float) — the single-argument overload — is NOT an
    // EV100 setter, despite this function's name/callers treating it as one.
    // Per its own header doc it's an unrelated "unitless" exposure knob meant
    // for matching non-physical engines (exposure=1.0 is its neutral point),
    // implemented as setExposure(aperture:1.0, shutter:1.2, sensitivity:100/exposure).
    // Feeding it a real photographic EV100 (~15, correct for our lux-calibrated
    // lights) was computing sensitivity≈6.7 ISO at a fixed f/1.0, 1.2s — an
    // absurdly light-hungry combo that blew every scene out to solid white.
    // Derive an actual physical exposure instead: fix aperture/ISO at
    // standard reference values and solve the shutter speed that yields the
    // requested EV100 (EV100 = log2(N²/t) at ISO 100 ⇒ t = N²/2^EV100).
    const float aperture = 16.0f;
    const float sensitivity = 100.0f;
    const float shutterSpeed = (aperture * aperture) / powf(2.0f, ev100);
    ((Camera*)camera)->setExposure(aperture, shutterSpeed, sensitivity);
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

FilamentView* filament_createView(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    return (FilamentView*)fe->engine->createView();
}

void filament_destroyView(FilamentEngine* fe, FilamentView* view) {
    if (!fe || !fe->engine || !view) return;
    auto* v = (View*)view;
    // Detach scene/camera first to avoid dangling references during destroy.
    v->setScene(nullptr);
    fe->engine->destroy(v);
}

void filament_viewSetScene(FilamentView* view, FilamentScene* scene) {
    if (!view || !scene) return;
    ((View*)view)->setScene((Scene*)scene);
}

void filament_viewSetCamera(FilamentView* view, FilamentCamera* camera) {
    if (!view || !camera) return;
    ((View*)view)->setCamera((Camera*)camera);
}

void filament_viewSetViewport(FilamentView* view, int x, int y, int width, int height) {
    if (!view) return;
    ((View*)view)->setViewport({x, y, (uint32_t)width, (uint32_t)height});
}

void filament_viewSetPostProcessing(FilamentView* view, bool enabled) {
    if (!view) return;
    ((View*)view)->setPostProcessingEnabled(enabled);
}

// MARK: - View options (bloom / SSAO / fog / vignette / TAA / AA / dithering / shadows)

static QualityLevel intToQualityLevel(int q) {
    switch (q) {
        case 0:  return QualityLevel::LOW;
        case 1:  return QualityLevel::MEDIUM;
        case 2:  return QualityLevel::HIGH;
        case 3:  return QualityLevel::ULTRA;
        default: return QualityLevel::MEDIUM;
    }
}

void filament_viewSetBloomOptions(FilamentView* view, FilamentBloomOptions o) {
    if (!view) return;
    View::BloomOptions opts;
    opts.enabled     = o.enabled;
    opts.strength    = o.strength;
    opts.levels      = (uint8_t)std::max(1, std::min(11, o.levels));
    opts.blendMode   = (o.blendMode >= 0.5f) ? View::BloomOptions::BlendMode::INTERPOLATE
                                            : View::BloomOptions::BlendMode::ADD;
    // Filament's BloomOptions `threshold` is a bool; we map header's float
    // (typically [0,1]) to "enable thresholding if positive".
    opts.threshold   = (o.threshold > 0.0f);
    // Anamorphism (header) maps to resolution in Filament. Default 384.
    opts.resolution  = 384;
    // quality is at index 5; just default MEDIUM for now.
    opts.quality     = QualityLevel::MEDIUM;
    ((View*)view)->setBloomOptions(opts);
}

void filament_viewSetAmbientOcclusionOptions(FilamentView* view,
                                             FilamentAmbientOcclusionOptions o) {
    if (!view) return;
    View::AmbientOcclusionOptions opts;
    opts.enabled     = o.enabled;
    opts.radius      = o.radius;
    opts.power       = o.power;
    opts.bias        = o.bias;
    opts.intensity   = o.intensity;
    opts.quality     = intToQualityLevel(o.quality);
    opts.bentNormals = o.bentNormals;
    ((View*)view)->setAmbientOcclusionOptions(opts);
}

void filament_viewSetMultiSampleAntiAliasingOptions(FilamentView* view,
                                                    FilamentMultiSampleAntiAliasingOptions o) {
    if (!view) return;
    View::MultiSampleAntiAliasingOptions opts;
    opts.enabled       = o.enabled;
    opts.sampleCount   = (uint8_t)std::max(1, std::min(255, o.sampleCount));
    opts.customResolve = o.customResolve;
    ((View*)view)->setMultiSampleAntiAliasingOptions(opts);
}

void filament_viewSetDynamicResolutionOptions(FilamentView* view,
                                              FilamentDynamicResolutionOptions o) {
    if (!view) return;
    View::DynamicResolutionOptions opts;
    opts.enabled            = o.enabled;
    opts.homogeneousScaling = o.homogeneousScaling;
    opts.minScale           = {o.minScaleX, o.minScaleY};
    opts.maxScale           = {o.maxScaleX, o.maxScaleY};
    opts.sharpness          = o.sharpness;
    opts.quality            = intToQualityLevel(o.quality);
    ((View*)view)->setDynamicResolutionOptions(opts);
}

void filament_viewSetHdrColorBufferQuality(FilamentView* view, int quality) {
    if (!view) return;
    View::RenderQuality rq;
    rq.hdrColorBuffer = (quality != 0) ? QualityLevel::HIGH : QualityLevel::LOW;
    ((View*)view)->setRenderQuality(rq);
}

void filament_viewSetFogOptions(FilamentView* view, FilamentFogOptions o) {
    if (!view) return;
    View::FogOptions opts;
    opts.enabled          = o.enabled;
    opts.distance         = o.distance;
    opts.height           = o.height;
    opts.heightFalloff    = o.heightFalloff;
    opts.density          = o.density;
    opts.color            = {o.r, o.g, o.b};
    opts.fogColorFromIbl  = o.fogColorFromIbl;
    opts.inScatteringStart = o.inScatteringStart;
    // Header's "inScatteringEnd" maps to Filament's inScatteringSize:
    // positive size activates sun in-scattering; we pass max(0, end - start).
    float span = std::max(0.0f, o.inScatteringEnd - o.inScatteringStart);
    opts.inScatteringSize = (span > 0.0f) ? std::max(0.001f, span) : -1.0f;
    ((View*)view)->setFogOptions(opts);
}

void filament_viewSetVignetteOptions(FilamentView* view, FilamentVignetteOptions o) {
    if (!view) return;
    View::VignetteOptions opts;
    opts.enabled = o.enabled;
    opts.midPoint = o.midPoint;
    // Header's "radius" maps to Filament's roundness.
    opts.roundness = std::max(0.0f, std::min(1.0f, o.radius));
    // Header's "blend" maps to Filament's feather.
    opts.feather = std::max(0.0f, std::min(1.0f, o.blend));
    ((View*)view)->setVignetteOptions(opts);
}

void filament_viewSetDithering(FilamentView* view, int mode) {
    if (!view) return;
    View::Dithering d;
    switch (mode) {
        case 0:  d = View::Dithering::NONE; break;
        case 1:  d = View::Dithering::TEMPORAL; break;
        case 2:  d = View::Dithering::NONE; break;  // MIN not exposed in this Filament version
        case 3:  d = View::Dithering::NONE; break;  // MAX not exposed either
        default: d = View::Dithering::TEMPORAL; break;
    }
    ((View*)view)->setDithering(d);
}

void filament_viewSetAntiAliasing(FilamentView* view, int mode) {
    if (!view) return;
    // Header mode is a bitmask: 0=NONE, 1=FXAA, 2=TAA. Filament's enum only
    // distinguishes NONE vs FXAA; TAA is toggled separately via TAA options.
    bool wantFxaa = (mode & 1) != 0;
    ((View*)view)->setAntiAliasing(wantFxaa ? View::AntiAliasing::FXAA
                                            : View::AntiAliasing::NONE);
}

void filament_viewSetTemporalAntiAliasingOptions(FilamentView* view,
                                                 FilamentTemporalAntiAliasingOptions o) {
    if (!view) return;
    View::TemporalAntiAliasingOptions opts;
    opts.filterWidth = o.filterWidth;
    // Header's "historyWeight" maps to Filament's "feedback" (1.0 = no AA,
    // 0.0 = full temporal accumulation). Clamp to [0, 1].
    opts.feedback = std::max(0.0f, std::min(1.0f, o.historyWeight));
    opts.sharpness = 0.0f;
    opts.lodBias = -1.0f;
    // TAA is "enabled" if any of FXAA-style AA was requested; we enable it
    // whenever the user asks via this setter.
    opts.enabled = o.enabled;
    // Filament's upscaling is a float factor; header's bool maps to 1.5x.
    opts.upscaling = o.upscaling ? 1.5f : 1.0f;
    // "varianceFilter" maps to BoxType::AABB_VARIANCE when true.
    opts.boxType = o.varianceFilter
        ? View::TemporalAntiAliasingOptions::BoxType::AABB_VARIANCE
        : View::TemporalAntiAliasingOptions::BoxType::AABB;
    opts.boxClipping = View::TemporalAntiAliasingOptions::BoxClipping::CLAMP;
    ((View*)view)->setTemporalAntiAliasingOptions(opts);
}

void filament_viewSetShadowType(FilamentView* view, int shadowType) {
    if (!view) return;
    View::ShadowType t;
    switch (shadowType) {
        case 0:  t = View::ShadowType::PCF; break;
        case 1:  t = View::ShadowType::VSM; break;
        case 2:  t = View::ShadowType::DPCF; break;
        case 3:  t = View::ShadowType::PCSS; break;
        case 4:  t = View::ShadowType::PCFd; break;
        default: t = View::ShadowType::PCF; break;
    }
    ((View*)view)->setShadowType(t);
}

void filament_viewSetShadowingEnabled(FilamentView* view, bool enabled) {
    if (!view) return;
    ((View*)view)->setShadowingEnabled(enabled);
}

void filament_viewSetColorGrading(FilamentView* view, FilamentColorGrading* grading) {
    if (!view) return;
    ColorGrading* cg = grading ? ((FilamentColorGrading*)grading)->grading : nullptr;
    ((View*)view)->setColorGrading(cg);
}

// ---------------------------------------------------------------------------
// ColorGrading builder
// ---------------------------------------------------------------------------

FilamentColorGrading* filament_createColorGrading(FilamentEngine* fe,
                                                  float exposure,
                                                  float whiteBalanceKelvin,
                                                  float contrast,
                                                  float saturation,
                                                  int   toneMapper,
                                                  float shadowGamma,
                                                  float midPoint,
                                                  float highlightGamma) {
    if (!fe || !fe->engine) return nullptr;
    ColorGrading::Builder builder;
    builder.toneMapper(toneMapperForInt(toneMapper));
    // Header passes only Kelvin; tint is fixed at 0.0.
    builder.whiteBalance(whiteBalanceKelvin, 0.0f);
    builder.contrast(contrast);
    builder.saturation(saturation);
    builder.exposure(exposure);
    builder.shadowsMidtonesHighlights(
        {shadowGamma, shadowGamma, shadowGamma, 0.0f},
        {midPoint,    midPoint,    midPoint,    0.0f},
        {highlightGamma, highlightGamma, highlightGamma, 0.0f},
        {0.0f, 0.333f, 0.55f, 1.0f});
    ColorGrading* cg = builder.build(*fe->engine);
    if (!cg) return nullptr;
    auto* fcg = new FilamentColorGrading();
    fcg->grading = cg;
    fcg->engine  = fe->engine;
    return (FilamentColorGrading*)fcg;
}

void filament_destroyColorGrading(FilamentEngine* fe, FilamentColorGrading* grading) {
    if (!fe || !grading) return;
    auto* fcg = (FilamentColorGrading*)grading;
    if (fcg->grading && fcg->engine) {
        fcg->engine->destroy(fcg->grading);
    }
    delete fcg;
}

// ---------------------------------------------------------------------------
// Material & Material Instance
// ---------------------------------------------------------------------------

FilamentMaterial* filament_loadMaterial(FilamentEngine* fe,
                                        const void* data, size_t size) {
    if (!fe || !fe->engine || !data) return nullptr;
    auto* mat = Material::Builder()
        .package(data, size)
        .build(*fe->engine);
    return (FilamentMaterial*)mat;
}

FilamentMaterial* filament_createMaterialInstance(FilamentMaterial* material) {
    if (!material) return nullptr;
    return (FilamentMaterial*)((Material*)material)->createInstance();
}

FilamentMaterial* filament_createDefaultMaterialInstance(FilamentEngine* fe) {
    if (!fe || !fe->engine || !fe->defaultMaterial) return nullptr;
    return (FilamentMaterial*)fe->defaultMaterial->createInstance();
}

FilamentMaterial* filament_createSubsurfaceMaterialInstance(FilamentEngine* fe) {
    if (!fe || !fe->engine || !fe->subsurfaceMaterial) return nullptr;
    return (FilamentMaterial*)fe->subsurfaceMaterial->createInstance();
}

void filament_engineDestroyMaterialInstance(FilamentEngine* fe, FilamentMaterial* instance) {
    if (!fe || !fe->engine || !instance) return;
    fe->engine->destroy((MaterialInstance*)instance);
}

void filament_materialSetFloat(FilamentMaterial* material,
                               const char* name, float value) {
    if (!material || !name) return;
    ((MaterialInstance*)material)->setParameter(name, value);
}

void filament_materialSetFloat2(FilamentMaterial* material,
                                const char* name, float x, float y) {
    if (!material || !name) return;
    ((MaterialInstance*)material)->setParameter(name, fmath::float2{x, y});
}

void filament_materialSetFloat3(FilamentMaterial* material,
                                const char* name, float x, float y, float z) {
    if (!material || !name) return;
    ((MaterialInstance*)material)->setParameter(name, fmath::float3{x, y, z});
}

void filament_materialSetFloat4(FilamentMaterial* material,
                                const char* name, float x, float y, float z, float w) {
    if (!material || !name) return;
    ((MaterialInstance*)material)->setParameter(name, fmath::float4{x, y, z, w});
}

void filament_destroyMaterial(FilamentMaterial* /*material*/) {
    // Managed by engine lifecycle.
}

/// Destroy a material via the engine. Must be called after all entities that
/// reference it have been removed from the scene, and before Engine::destroy().
void filament_engineDestroyMaterial(FilamentEngine* fe, FilamentMaterial* material) {
    if (!fe || !fe->engine || !material) return;
    fe->engine->destroy((Material*)material);
}

// ---------------------------------------------------------------------------
// Helpers: PBR defaults; geometry build pipeline
// ---------------------------------------------------------------------------

static void applyPbrDefaults(MaterialInstance* mi) {
    if (!mi) return;
    mi->setParameter("baseColorFactor",     fmath::float4{0.72f, 0.72f, 0.78f, 1.0f});
    mi->setParameter("metallicFactor",      0.0f);
    mi->setParameter("roughnessFactor",     0.35f);
    mi->setParameter("reflectance",         0.5f);
    mi->setParameter("clearCoatFactor",     0.08f);
    mi->setParameter("clearCoatRoughness",  0.0f);
    mi->setParameter("anisotropy",          0.0f);
    mi->setParameter("normalDetail",        0.22f);
    mi->setParameter("roughnessVariation",  0.16f);
    mi->setParameter("textureScale",        1.0f);
    mi->setParameter("roughnessPattern",    0.0f);  // smooth
}

struct Vertex {
    fmath::float3 position;
    fmath::float4 tangentQ;
    fmath::float2 uv;
    // Filled in by buildRenderable(), NOT by call sites (all of which
    // aggregate-init with just {position, tangentQ, uv} and leave this
    // zeroed). Position relative to this entity's own bounding-box center,
    // computed once at mesh-build time — i.e. before any *world* offset
    // this shape happens to sit at. Procedural materials sample from this
    // instead of world position so surface detail stays glued to the object
    // instead of sliding through it as the shape is moved.
    fmath::float3 localPosition;
};

// VertexBuffer::BufferDescriptor / IndexBuffer::BufferDescriptor do NOT copy
// the memory they're given — they just wrap the pointer, and the actual GPU
// upload happens later, asynchronously, on Filament's backend/driver thread.
// Without a release callback the caller is expected to keep that memory
// valid until then; buildRenderable used to hand over pointers straight into
// a std::vector owned by the calling filament_create*() function, which
// destroyed (and freed) that vector the moment it returned — well before the
// backend thread actually read it. The result was a data race: depending on
// what reused that freed heap memory first, the GPU sometimes uploaded
// garbage vertex positions, rendering as scrambled/shattered geometry. Heap-
// copy the data and let Filament's own callback free it once it's actually
// done with the buffer.
template <typename T>
static void releaseHeapVector(void*, size_t, void* user) {
    delete static_cast<std::vector<T>*>(user);
}

// `material`, when non-null, is an already-configured MaterialInstance*
// (created via filament_createDefaultMaterialInstance and parameterized on
// the Swift side) that's attached directly to this renderable — it is NOT
// copied or re-instantiated, so the same instance can legitimately back many
// renderables at once (the Swift-side material cache relies on this). If
// null, a private fallback instance with flat PBR defaults is created and
// owned by this entity so geometry is never invisible.
static FilamentEntity* buildRenderable(FilamentEngine* fe,
                                       FilamentScene* scene,
                                       FilamentMaterial* material,
                                       const std::vector<Vertex>& vertices,
                                       const std::vector<uint32_t>& indices,
                                       const fmath::float3& bbMin,
                                       const fmath::float3& bbMax) {
    if (!fe || !fe->engine || !scene || vertices.empty() || indices.empty()) return nullptr;

    auto* engine = fe->engine;
    auto* scn = (Scene*)scene;

    auto* vb = VertexBuffer::Builder()
        .vertexCount((uint32_t)vertices.size())
        .bufferCount(1)
        .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3,
                    offsetof(Vertex, position), sizeof(Vertex))
        .attribute(VertexAttribute::TANGENTS, 0, VertexBuffer::AttributeType::FLOAT4,
                    offsetof(Vertex, tangentQ), sizeof(Vertex))
        .attribute(VertexAttribute::UV0,     0, VertexBuffer::AttributeType::FLOAT2,
                    offsetof(Vertex, uv), sizeof(Vertex))
        .attribute(VertexAttribute::CUSTOM0, 0, VertexBuffer::AttributeType::FLOAT3,
                    offsetof(Vertex, localPosition), sizeof(Vertex))
        .build(*engine);

    auto* heapVertices = new std::vector<Vertex>(vertices);
    // Anchor procedural-material coordinates to the entity's own bounding-box
    // center rather than world space. bbMin/bbMax are computed by the caller
    // from these same (already CPU-transformed) vertex positions, so this
    // stays self-consistent for every shape kind — including arbitrary
    // `.mesh` triangle soups from rotated/mapped geometry, which carry no
    // other notion of "local space" by the time they reach this function.
    //
    // Also normalize by the entity's own half-extent so studio_pbr.mat's
    // noise frequency reads as a consistent number of pattern repeats
    // regardless of the object's absolute size in world units. Grasshopper-
    // style parametric geometry can be any scale; without this, a small
    // object (say a unit-radius sphere) samples well under one full noise
    // period across its whole surface — instead of a repeating material
    // texture, that shows up as a single soft, randomly-shaped blob smeared
    // across the object (see studio_pbr.mat).
    const fmath::float3 localOrigin = (bbMin + bbMax) * 0.5f;
    const fmath::float3 halfExtent = (bbMax - bbMin) * 0.5f;
    const float localScale = std::max({halfExtent.x, halfExtent.y, halfExtent.z, 1e-4f});
    for (auto& v : *heapVertices) {
        v.localPosition = (v.position - localOrigin) / localScale;
    }
    vb->setBufferAt(*engine, 0,
        VertexBuffer::BufferDescriptor(heapVertices->data(), heapVertices->size() * sizeof(Vertex),
            releaseHeapVector<Vertex>, heapVertices));

    auto* ib = IndexBuffer::Builder()
        .indexCount((uint32_t)indices.size())
        .bufferType(IndexBuffer::IndexType::UINT)
        .build(*engine);
    auto* heapIndices = new std::vector<uint32_t>(indices);
    ib->setBuffer(*engine,
        IndexBuffer::BufferDescriptor(heapIndices->data(), heapIndices->size() * sizeof(uint32_t),
            releaseHeapVector<uint32_t>, heapIndices));

    MaterialInstance* mi = (MaterialInstance*)material;
    bool ownsInstance = false;
    if (!mi) {
        mi = fe->defaultMaterial ? fe->defaultMaterial->createInstance() : nullptr;
        if (mi) {
            applyPbrDefaults(mi);
            ownsInstance = true;
        }
    }
    if (!mi) {
        engine->destroy(vb);
        engine->destroy(ib);
        return nullptr;
    }

    auto& em = utils::EntityManager::get();
    utils::Entity entity = em.create();

    auto& tm = engine->getTransformManager();
    tm.create(entity);
    TransformManager::Instance tinst = tm.getInstance(entity);

    RenderableManager::Builder(1)
        .boundingBox(Box().set(bbMin, bbMax))
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, vb, ib, 0, (uint32_t)indices.size())
        .material(0, mi)
        .culling(true)
        // Filament defaults this to false; without it no shape ever throws a
        // shadow onto the ground plane or other geometry, so everything reads
        // as floating in a void regardless of how the lights/shadow view
        // options are configured.
        .castShadows(true)
        .build(*engine, entity);

    scn->addEntity(entity);

    auto* feEntity = new FilamentEntity();
    feEntity->entity = entity;
    feEntity->vb = vb;
    feEntity->ib = ib;
    feEntity->materialInstance = mi;
    feEntity->ownsMaterialInstance = ownsInstance;
    feEntity->transformInstance = tinst;
    feEntity->engine = engine;
    feEntity->isLight = false;

    return (FilamentEntity*)feEntity;
}

void filament_removeEntity(FilamentScene* scene, FilamentEntity* entity) {
    if (!scene || !entity) return;
    auto* feEntity = (FilamentEntity*)entity;
    auto* scn = (Scene*)scene;

    scn->remove(feEntity->entity);

    if (feEntity->engine) {
        auto& tm = feEntity->engine->getTransformManager();
        if (!feEntity->isLight) {
            tm.destroy(feEntity->entity);
        }
        if (feEntity->vb) feEntity->engine->destroy(feEntity->vb);
        if (feEntity->ib) feEntity->engine->destroy(feEntity->ib);
        // Shared (cached) material instances outlive any single entity and
        // are destroyed separately via filament_engineDestroyMaterialInstance.
        if (feEntity->ownsMaterialInstance && feEntity->materialInstance) {
            feEntity->engine->destroy(feEntity->materialInstance);
        }
    }

    auto& em = utils::EntityManager::get();
    em.destroy(feEntity->entity);
    delete feEntity;
}

// ---------------------------------------------------------------------------
// Entity transforms
// ---------------------------------------------------------------------------

void filament_entitySetTransform(FilamentEntity* entity, const float* matrix4x4) {
    if (!entity || !matrix4x4) return;
    auto* feEntity = (FilamentEntity*)entity;
    if (!feEntity->engine) return;
    // Filament's mat4f is column-major; interpret the float[16] directly.
    fmath::mat4f m;
    std::memcpy(&m, matrix4x4, sizeof(float) * 16);
    auto& tm = feEntity->engine->getTransformManager();
    tm.setTransform(feEntity->transformInstance, m);
}

void filament_entityGetTransform(FilamentEntity* entity, float* outMatrix) {
    if (!entity || !outMatrix) return;
    auto* feEntity = (FilamentEntity*)entity;
    if (!feEntity->engine) return;
    auto& tm = feEntity->engine->getTransformManager();
    const fmath::mat4f& m = tm.getTransform(feEntity->transformInstance);
    std::memcpy(outMatrix, &m, sizeof(float) * 16);
}

// ---------------------------------------------------------------------------
// Sphere
// ---------------------------------------------------------------------------

FilamentEntity* filament_createSphere(FilamentEngine* fe, FilamentScene* scene,
                                      FilamentMaterial* material,
                                      float cx, float cy, float cz,
                                      float radius, int segments) {
    if (segments < 8) segments = 8;
    int rings = std::max(segments / 2, 4);

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    for (int j = 0; j <= rings; j++) {
        float phi = (float)M_PI * (float)j / (float)rings;
        float y = cosf(phi);
        float r = sinf(phi);
        for (int i = 0; i <= segments; i++) {
            float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
            float x = r * cosf(theta);
            float z = r * sinf(theta);
            fmath::float3 n{x, y, z};
            // Tangent along increasing theta (d(position)/d(theta)); see
            // tangentFrameToQuat above for why this avoids the fixed-
            // reference singularity that normalToTangentQuat(n) alone hits
            // somewhere on every full sphere sweep.
            fmath::float3 t{-sinf(theta), 0.0f, cosf(theta)};
            Vertex v;
            v.position = fmath::float3{cx, cy, cz} + n * radius;
            v.tangentQ = tangentFrameToQuat(t, n);
            v.uv = {(float)i / (float)segments, (float)j / (float)rings};
            verts.push_back(v);
        }
    }

    int cols = segments + 1;
    for (int j = 0; j < rings; j++) {
        for (int i = 0; i < segments; i++) {
            uint32_t a = j * cols + i, b = a + 1;
            uint32_t c = (j + 1) * cols + i, d = c + 1;
            indices.push_back(a); indices.push_back(c); indices.push_back(b);
            indices.push_back(b); indices.push_back(c); indices.push_back(d);
        }
    }

    fmath::float3 bbMin{cx - radius, cy - radius, cz - radius};
    fmath::float3 bbMax{cx + radius, cy + radius, cz + radius};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Box
// ---------------------------------------------------------------------------

FilamentEntity* filament_createBox(FilamentEngine* fe, FilamentScene* scene,
                                   FilamentMaterial* material,
                                   float minX, float minY, float minZ,
                                   float maxX, float maxY, float maxZ) {
    struct Face { fmath::float3 n; fmath::float3 v[4]; fmath::float2 u[4]; };
    Face faces[6] = {
        {{ 1, 0, 0}, {{maxX,minY,maxZ},{maxX,maxY,maxZ},{maxX,maxY,minZ},{maxX,minY,minZ}}, {{0,0},{0,1},{1,1},{1,0}}},
        {{-1, 0, 0}, {{minX,minY,minZ},{minX,maxY,minZ},{minX,maxY,maxZ},{minX,minY,maxZ}}, {{0,0},{0,1},{1,1},{1,0}}},
        {{ 0, 1, 0}, {{minX,maxY,maxZ},{maxX,maxY,maxZ},{maxX,maxY,minZ},{minX,maxY,minZ}}, {{0,0},{0,1},{1,1},{1,0}}},
        {{ 0,-1, 0}, {{minX,minY,minZ},{maxX,minY,minZ},{maxX,minY,maxZ},{minX,minY,maxZ}}, {{0,0},{0,1},{1,1},{1,0}}},
        {{ 0, 0, 1}, {{maxX,minY,maxZ},{maxX,maxY,maxZ},{minX,maxY,maxZ},{minX,minY,maxZ}}, {{0,0},{0,1},{1,1},{1,0}}},
        {{ 0, 0,-1}, {{minX,minY,minZ},{minX,maxY,minZ},{maxX,maxY,minZ},{maxX,minY,minZ}}, {{0,0},{0,1},{1,1},{1,0}}},
    };

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    for (int f = 0; f < 6; f++) {
        uint32_t base = (uint32_t)verts.size();
        fmath::float4 tq = normalToTangentQuat(faces[f].n);
        for (int v = 0; v < 4; v++) {
            Vertex vt;
            vt.position = faces[f].v[v];
            vt.tangentQ = tq;
            vt.uv = faces[f].u[v];
            verts.push_back(vt);
        }
        // Winding is CCW when viewed from outside each face.  With
        // back-face culling enabled, reversing this causes orbit-dependent
        // missing faces.
        indices.push_back(base); indices.push_back(base+2); indices.push_back(base+1);
        indices.push_back(base); indices.push_back(base+3); indices.push_back(base+2);
    }

    fmath::float3 bbMin{minX, minY, minZ};
    fmath::float3 bbMax{maxX, maxY, maxZ};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Cylinder
// ---------------------------------------------------------------------------

FilamentEntity* filament_createCylinder(FilamentEngine* fe, FilamentScene* scene,
                                        FilamentMaterial* material,
                                        float cx, float cy, float cz,
                                        float radius, float height, int segments) {
    if (segments < 8) segments = 8;
    float hh = height * 0.5f;
    float topY = cy + hh;
    float botY = cy - hh;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    // Side walls.
    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        float x = cosf(theta), z = sinf(theta);
        fmath::float3 n{x, 0, z};
        fmath::float3 t{-sinf(theta), 0.0f, cosf(theta)};
        fmath::float4 tq = tangentFrameToQuat(t, n);
        float u = (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*x, topY, cz + radius*z}, tq, {u, 0}});
        verts.push_back({fmath::float3{cx + radius*x, botY, cz + radius*z}, tq, {u, 1}});
    }
    for (int i = 0; i < segments; i++) {
        uint32_t t0 = i*2, t1 = i*2+1, t2 = (i+1)*2, t3 = (i+1)*2+1;
        indices.push_back(t0); indices.push_back(t2); indices.push_back(t1);
        indices.push_back(t1); indices.push_back(t2); indices.push_back(t3);
    }

    // Top cap.
    fmath::float4 topQ = normalToTangentQuat(fmath::float3{0, 1, 0});
    uint32_t tc = (uint32_t)verts.size();
    verts.push_back({fmath::float3{cx, topY, cz}, topQ, {0.5f, 0.5f}});
    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*cosf(theta), topY, cz + radius*sinf(theta)},
                         topQ, {cosf(theta)*0.5f+0.5f, sinf(theta)*0.5f+0.5f}});
    }
    for (int i = 0; i < segments; i++) {
        indices.push_back(tc); indices.push_back(tc+1+i+1); indices.push_back(tc+1+i);
    }

    // Bottom cap.
    fmath::float4 botQ = normalToTangentQuat(fmath::float3{0, -1, 0});
    uint32_t bc = (uint32_t)verts.size();
    verts.push_back({fmath::float3{cx, botY, cz}, botQ, {0.5f, 0.5f}});
    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*cosf(theta), botY, cz + radius*sinf(theta)},
                         botQ, {cosf(theta)*0.5f+0.5f, sinf(theta)*0.5f+0.5f}});
    }
    for (int i = 0; i < segments; i++) {
        indices.push_back(bc); indices.push_back(bc+1+i); indices.push_back(bc+1+i+1);
    }

    fmath::float3 bbMin{cx - radius, botY, cz - radius};
    fmath::float3 bbMax{cx + radius, topY, cz + radius};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Cone
// ---------------------------------------------------------------------------

FilamentEntity* filament_createCone(FilamentEngine* fe, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float cx, float cy, float cz,
                                    float radius, float height, int segments) {
    if (segments < 8) segments = 8;
    float hh = height * 0.5f;
    float topY = cy + hh;
    float botY = cy - hh;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    float slopeLen = sqrtf(radius*radius + height*height);
    float nxScale = height / slopeLen;
    float nyScale = radius / slopeLen;

    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        float x = cosf(theta), z = sinf(theta);
        fmath::float3 n{x * nxScale, nyScale, z * nxScale};
        n = normalize(n);
        fmath::float3 t{-sinf(theta), 0.0f, cosf(theta)};
        fmath::float4 tq = tangentFrameToQuat(t, n);
        float u = (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*x, botY, cz + radius*z}, tq, {u, 1}});
    }
    uint32_t apex = (uint32_t)verts.size();
    fmath::float3 apexN{0, 1, 0};
    fmath::float4 apexQ = normalToTangentQuat(apexN);
    verts.push_back({fmath::float3{cx, topY, cz}, apexQ, {0.5f, 0}});

    for (int i = 0; i < segments; i++) {
        indices.push_back((uint32_t)i);
        indices.push_back((uint32_t)(i + 1));
        indices.push_back(apex);
    }

    // Bottom cap.
    fmath::float4 botQ = normalToTangentQuat(fmath::float3{0, -1, 0});
    uint32_t bc = (uint32_t)verts.size();
    verts.push_back({fmath::float3{cx, botY, cz}, botQ, {0.5f, 0.5f}});
    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*cosf(theta), botY, cz + radius*sinf(theta)},
                         botQ, {cosf(theta)*0.5f+0.5f, sinf(theta)*0.5f+0.5f}});
    }
    for (int i = 0; i < segments; i++) {
        indices.push_back(bc); indices.push_back(bc+1+i); indices.push_back(bc+1+i+1);
    }

    fmath::float3 bbMin{cx - radius, botY, cz - radius};
    fmath::float3 bbMax{cx + radius, topY, cz + radius};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Torus
// ---------------------------------------------------------------------------

FilamentEntity* filament_createTorus(FilamentEngine* fe, FilamentScene* scene,
                                     FilamentMaterial* material,
                                     float cx, float cy, float cz,
                                     float majorR, float minorR,
                                     int majorSeg, int minorSeg) {
    if (majorSeg < 16) majorSeg = 16;
    if (minorSeg < 8) minorSeg = 8;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    for (int i = 0; i <= majorSeg; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)majorSeg;
        float cosT = cosf(theta), sinT = sinf(theta);
        float ringCx = cosT * majorR, ringCz = sinT * majorR;

        for (int j = 0; j <= minorSeg; j++) {
            float phi = 2.0f * (float)M_PI * (float)j / (float)minorSeg;
            float cosP = cosf(phi), sinP = sinf(phi);

            float px = ringCx + cosT * cosP * minorR;
            float py = sinP * minorR;
            float pz = ringCz + sinT * cosP * minorR;

            fmath::float3 n{cosT * cosP, sinP, sinT * cosP};
            n = normalize(n);
            // Tangent along the major-loop direction (d(position)/d(theta));
            // see tangentFrameToQuat above — a torus's normal also sweeps
            // the full unit sphere, so a fixed-reference construction would
            // hit the same singularity a sphere does.
            fmath::float3 t{-sinT, 0.0f, cosT};

            Vertex v;
            v.position = fmath::float3{cx + px, cy + py, cz + pz};
            v.tangentQ = tangentFrameToQuat(t, n);
            v.uv = {(float)i/(float)majorSeg, (float)j/(float)minorSeg};
            verts.push_back(v);
        }
    }

    int cols = minorSeg + 1;
    for (int i = 0; i < majorSeg; i++) {
        for (int j = 0; j < minorSeg; j++) {
            uint32_t a = i*cols + j, b = a + 1;
            uint32_t c = (i+1)*cols + j, d = c + 1;
            indices.push_back(a); indices.push_back(c); indices.push_back(b);
            indices.push_back(b); indices.push_back(c); indices.push_back(d);
        }
    }

    float r = majorR + minorR;
    fmath::float3 bbMin{cx - r, cy - minorR, cz - r};
    fmath::float3 bbMax{cx + r, cy + minorR, cz + r};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Disc (circle in XZ plane, Y-up)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createDisc(FilamentEngine* fe, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float cx, float cy, float cz,
                                    float radius, int segments) {
    if (segments < 8) segments = 8;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    fmath::float4 tq = normalToTangentQuat(fmath::float3{0, 1, 0});

    verts.push_back({fmath::float3{cx, cy, cz}, tq, {0.5f, 0.5f}});
    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        float x = cosf(theta), z = sinf(theta);
        verts.push_back({fmath::float3{cx + radius*x, cy, cz + radius*z},
                         tq, {x*0.5f+0.5f, z*0.5f+0.5f}});
    }
    for (int i = 0; i < segments; i++) {
        indices.push_back(0);
        indices.push_back((uint32_t)(i + 2));
        indices.push_back((uint32_t)(i + 1));
    }

    fmath::float3 bbMin{cx - radius, cy - 0.01f, cz - radius};
    fmath::float3 bbMax{cx + radius, cy + 0.01f, cz + radius};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Plane (in XZ plane)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createPlane(FilamentEngine* fe, FilamentScene* scene,
                                     FilamentMaterial* material,
                                     float cx, float cy, float cz,
                                     float width, float depth) {
    float hw = width * 0.5f, hd = depth * 0.5f;
    fmath::float4 tq = normalToTangentQuat(fmath::float3{0, 1, 0});

    std::vector<Vertex> verts = {
        {fmath::float3{cx - hw, cy, cz - hd}, tq, {0, 0}},
        {fmath::float3{cx + hw, cy, cz - hd}, tq, {1, 0}},
        {fmath::float3{cx + hw, cy, cz + hd}, tq, {1, 1}},
        {fmath::float3{cx - hw, cy, cz + hd}, tq, {0, 1}},
    };
    std::vector<uint32_t> indices = {0, 2, 1, 0, 3, 2};

    fmath::float3 bbMin{cx - hw, cy - 0.01f, cz - hd};
    fmath::float3 bbMax{cx + hw, cy + 0.01f, cz + hd};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Line (thin oriented cylinder)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createLine(FilamentEngine* fe, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float x0, float y0, float z0,
                                    float x1, float y1, float z1,
                                    float radius) {
    int segments = 8;
    fmath::float3 start{x0, y0, z0}, end{x1, y1, z1};
    fmath::float3 dir = end - start;
    float len = length(dir);
    if (len < 0.0001f) return nullptr;
    fmath::float3 axis = dir / len;

    fmath::float3 up{0, 1, 0};
    if (fabsf(dot(axis, up)) > 0.999f) up = fmath::float3{1, 0, 0};
    fmath::float3 right = normalize(cross(axis, up));
    fmath::float3 fwd   = normalize(cross(right, axis));

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        fmath::float3 n = normalize(right * cosf(theta) + fwd * sinf(theta));
        fmath::float3 t = normalize(right * -sinf(theta) + fwd * cosf(theta));
        fmath::float4 tq = tangentFrameToQuat(t, n);
        float u = (float)i / (float)segments;
        verts.push_back({start + n * radius, tq, {0, u}});
        verts.push_back({end   + n * radius, tq, {1, u}});
    }

    for (int i = 0; i < segments; i++) {
        uint32_t t0 = i*2, t1 = i*2+1, t2 = (i+1)*2, t3 = (i+1)*2+1;
        indices.push_back(t0); indices.push_back(t2); indices.push_back(t1);
        indices.push_back(t1); indices.push_back(t2); indices.push_back(t3);
    }

    fmath::float3 bbMin{fminf(x0,x1)-radius, fminf(y0,y1)-radius, fminf(z0,z1)-radius};
    fmath::float3 bbMax{fmaxf(x0,x1)+radius, fmaxf(y0,y1)+radius, fmaxf(z0,z1)+radius};
    return buildRenderable(fe, scene, material, verts, indices, bbMin, bbMax);
}

// ---------------------------------------------------------------------------
// Polygon (extruded)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createPolygon(FilamentEngine* fe, FilamentScene* scene,
                                       FilamentMaterial* material,
                                       const float* points, int count,
                                       float extrusion) {
    if (count < 3 || !points) return nullptr;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    fmath::float3 n{0, 1, 0};
    fmath::float3 a{points[0], points[1], points[2]};
    fmath::float3 b{points[3], points[4], points[5]};
    fmath::float3 c{points[6], points[7], points[8]};
    n = normalize(cross(b - a, c - a));
    if (n.y < 0) n = -n;

    float he = extrusion * 0.5f;
    fmath::float3 ext = n * he;

    std::vector<fmath::float3> poly;
    for (int i = 0; i < count; i++) {
        poly.push_back(fmath::float3{points[i*3], points[i*3+1], points[i*3+2]});
    }

    fmath::float3 centroid{0,0,0};
    for (auto& p : poly) centroid = centroid + p;
    centroid = centroid / (float)count;

    fmath::float4 topQ = normalToTangentQuat(n);
    uint32_t tc = (uint32_t)verts.size();
    verts.push_back({centroid + ext, topQ, {0.5f, 0.5f}});
    for (int i = 0; i <= count; i++) {
        auto& p = poly[i % count];
        verts.push_back({p + ext, topQ, {0, 0}});
    }
    for (int i = 0; i < count; i++) {
        indices.push_back(tc);
        indices.push_back(tc+1+i+1);
        indices.push_back(tc+1+i);
    }

    fmath::float4 botQ = normalToTangentQuat(-n);
    uint32_t bc = (uint32_t)verts.size();
    verts.push_back({centroid - ext, botQ, {0.5f, 0.5f}});
    for (int i = 0; i <= count; i++) {
        auto& p = poly[i % count];
        verts.push_back({p - ext, botQ, {0, 0}});
    }
    for (int i = 0; i < count; i++) {
        indices.push_back(bc);
        indices.push_back(bc+1+i);
        indices.push_back(bc+1+i+1);
    }

    for (int i = 0; i < count; i++) {
        auto& p0 = poly[i];
        auto& p1 = poly[(i+1)%count];
        fmath::float3 edge = p1 - p0;
        fmath::float3 wallN = normalize(cross(edge, n));
        fmath::float4 wallQ = normalToTangentQuat(wallN);
        uint32_t base = (uint32_t)verts.size();
        verts.push_back({p0 + ext, wallQ, {0, 0}});
        verts.push_back({p1 + ext, wallQ, {1, 0}});
        verts.push_back({p1 - ext, wallQ, {1, 1}});
        verts.push_back({p0 - ext, wallQ, {0, 1}});
        indices.push_back(base); indices.push_back(base+1); indices.push_back(base+2);
        indices.push_back(base); indices.push_back(base+2); indices.push_back(base+3);
    }

    float mnX=1e9f, mnY=1e9f, mnZ=1e9f, mxX=-1e9f, mxY=-1e9f, mxZ=-1e9f;
    for (auto& v : verts) {
        mnX = fminf(mnX, v.position.x); mxX = fmaxf(mxX, v.position.x);
        mnY = fminf(mnY, v.position.y); mxY = fmaxf(mxY, v.position.y);
        mnZ = fminf(mnZ, v.position.z); mxZ = fmaxf(mxZ, v.position.z);
    }
    return buildRenderable(fe, scene, material, verts, indices,
                           fmath::float3{mnX,mnY,mnZ}, fmath::float3{mxX,mxY,mxZ});
}

// ---------------------------------------------------------------------------
// Surface strip (loft between two curves)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createSurfaceStrip(FilamentEngine* fe, FilamentScene* scene,
                                            FilamentMaterial* material,
                                            const float* curveA, int countA,
                                            const float* curveB, int countB) {
    if (countA < 2 || countB < 2 || !curveA || !curveB) return nullptr;

    std::vector<Vertex> verts;
    std::vector<uint32_t> indices;

    int count = std::max(countA, countB);

    auto sample = [](const float* pts, int n, int idx, int total) -> fmath::float3 {
        float t = (float)idx / (float)(total - 1);
        float seg = t * (float)(n - 1);
        int i0 = (int)seg, i1 = std::min(i0 + 1, n - 1);
        float frac = seg - (float)i0;
        fmath::float3 p0{pts[i0*3], pts[i0*3+1], pts[i0*3+2]};
        fmath::float3 p1{pts[i1*3], pts[i1*3+1], pts[i1*3+2]};
        return p0 + (p1 - p0) * frac;
    };

    for (int i = 0; i < count; i++) {
        fmath::float3 pa = sample(curveA, countA, i, count);
        fmath::float3 pb = sample(curveB, countB, i, count);
        fmath::float3 n = normalize(fmath::float3{0, 1, 0});
        fmath::float4 tq = normalToTangentQuat(n);
        float u = (float)i / (float)(count - 1);
        verts.push_back({pa, tq, {u, 0}});
        verts.push_back({pb, tq, {u, 1}});
    }

    for (int i = 0; i < count - 1; i++) {
        uint32_t a0 = i*2, a1 = i*2+1;
        uint32_t b0 = (i+1)*2, b1 = (i+1)*2+1;
        indices.push_back(a0); indices.push_back(b0); indices.push_back(a1);
        indices.push_back(a1); indices.push_back(b0); indices.push_back(b1);
    }

    float mnX=1e9f, mnY=1e9f, mnZ=1e9f, mxX=-1e9f, mxY=-1e9f, mxZ=-1e9f;
    for (auto& v : verts) {
        mnX = fminf(mnX, v.position.x); mxX = fmaxf(mxX, v.position.x);
        mnY = fminf(mnY, v.position.y); mxY = fmaxf(mxY, v.position.y);
        mnZ = fminf(mnZ, v.position.z); mxZ = fmaxf(mxZ, v.position.z);
    }
    return buildRenderable(fe, scene, material, verts, indices,
                           fmath::float3{mnX,mnY,mnZ}, fmath::float3{mxX,mxY,mxZ});
}

// ---------------------------------------------------------------------------
// Generic mesh (thin wrapper over buildRenderable for arbitrary triangle
// meshes — extrude/revolve/sweep/boolean results from the Swift-side kernel)
// ---------------------------------------------------------------------------

FilamentEntity* filament_createMesh(FilamentEngine* fe, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    const float* positions, const float* normals, int vertexCount,
                                    const uint32_t* indices, int indexCount) {
    if (!positions || !normals || !indices || vertexCount <= 0 || indexCount <= 0) return nullptr;

    std::vector<Vertex> verts;
    verts.reserve((size_t)vertexCount);
    fmath::float3 mn{1e9f, 1e9f, 1e9f}, mx{-1e9f, -1e9f, -1e9f};
    for (int i = 0; i < vertexCount; i++) {
        fmath::float3 p{positions[i*3], positions[i*3+1], positions[i*3+2]};
        fmath::float3 n{normals[i*3], normals[i*3+1], normals[i*3+2]};
        Vertex v;
        v.position = p;
        v.tangentQ = normalToTangentQuat(n);
        v.uv = {0, 0};
        verts.push_back(v);
        mn = fmath::float3{fminf(mn.x, p.x), fminf(mn.y, p.y), fminf(mn.z, p.z)};
        mx = fmath::float3{fmaxf(mx.x, p.x), fmaxf(mx.y, p.y), fmaxf(mx.z, p.z)};
    }

    std::vector<uint32_t> idx(indices, indices + indexCount);

    return buildRenderable(fe, scene, material, verts, idx, mn, mx);
}

// ---------------------------------------------------------------------------
// Lights
// ---------------------------------------------------------------------------

FilamentEntity* filament_createDirectionalLight(FilamentEngine* fe,
                                                FilamentScene* scene,
                                                float dirX, float dirY, float dirZ,
                                                float r, float g, float b,
                                                float intensity,
                                                bool castsShadows) {
    if (!fe || !fe->engine || !scene) return nullptr;
    auto& em = utils::EntityManager::get();
    utils::Entity e = em.create();

    LightManager::Builder(LightManager::Type::DIRECTIONAL)
        .direction({dirX, dirY, dirZ})
        .color({r, g, b})
        .intensity(intensity)
        .castShadows(castsShadows)
        .build(*fe->engine, e);

    ((Scene*)scene)->addEntity(e);

    auto* ent = new FilamentEntity();
    ent->entity = e;
    ent->engine = fe->engine;
    ent->isLight = true;
    return (FilamentEntity*)ent;
}

FilamentEntity* filament_createPointLight(FilamentEngine* fe,
                                          FilamentScene* scene,
                                          float posX, float posY, float posZ,
                                          float r, float g, float b,
                                          float intensity) {
    if (!fe || !fe->engine || !scene) return nullptr;
    auto& em = utils::EntityManager::get();
    utils::Entity e = em.create();

    LightManager::Builder(LightManager::Type::POINT)
        .position({posX, posY, posZ})
        .color({r, g, b})
        .intensity(intensity)
        .build(*fe->engine, e);

    ((Scene*)scene)->addEntity(e);

    auto* ent = new FilamentEntity();
    ent->entity = e;
    ent->engine = fe->engine;
    ent->isLight = true;
    return (FilamentEntity*)ent;
}

FilamentEntity* filament_createSpotLight(FilamentEngine* fe,
                                         FilamentScene* scene,
                                         float posX, float posY, float posZ,
                                         float dirX, float dirY, float dirZ,
                                         float r, float g, float b,
                                         float intensity,
                                         float coneInner, float coneOuter) {
    if (!fe || !fe->engine || !scene) return nullptr;
    auto& em = utils::EntityManager::get();
    utils::Entity e = em.create();

    LightManager::Builder(LightManager::Type::SPOT)
        .position({posX, posY, posZ})
        .direction({dirX, dirY, dirZ})
        .color({r, g, b})
        .intensity(intensity)
        .spotLightCone(coneInner, coneOuter)
        .build(*fe->engine, e);

    ((Scene*)scene)->addEntity(e);

    auto* ent = new FilamentEntity();
    ent->entity = e;
    ent->engine = fe->engine;
    ent->isLight = true;
    return (FilamentEntity*)ent;
}

void filament_lightUpdateDirectional(FilamentEntity* light,
                                     float dirX, float dirY, float dirZ,
                                     float r, float g, float b,
                                     float intensity,
                                     bool castsShadows) {
    if (!light) return;
    auto* fe = (FilamentEntity*)light;
    if (!fe->engine || !fe->isLight) return;
    auto& lm = fe->engine->getLightManager();
    LightManager::Instance inst = lm.getInstance(fe->entity);
    if (!inst) return;
    lm.setDirection(inst, {dirX, dirY, dirZ});
    lm.setColor(inst, {r, g, b});
    lm.setIntensity(inst, intensity);
    lm.setShadowCaster(inst, castsShadows);
}

// ---------------------------------------------------------------------------
// IBL / Skybox via Filament's Ktx1Reader
// ---------------------------------------------------------------------------

static Texture* loadCubemapKtx(Engine* engine, const char* path) {
    if (!path) return nullptr;
    std::ifstream file(path, std::ios::binary);
    if (!file.good()) {
        NSLog(@"FilamentBridge: failed to open KTX file %s", path);
        return nullptr;
    }
    file.seekg(0, std::ios::end);
    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);
    if (size <= 0) {
        NSLog(@"FilamentBridge: KTX file %s has zero size", path);
        return nullptr;
    }
    std::vector<uint8_t> data((size_t)size);
    if (!file.read(reinterpret_cast<char*>(data.data()), size)) {
        NSLog(@"FilamentBridge: failed to read KTX file %s", path);
        return nullptr;
    }
    // Must be heap-allocated: this createTexture(Engine*, Ktx1Bundle*, bool) overload
    // takes ownership and deletes the bundle asynchronously once the GPU upload
    // completes (during a later render frame), so a stack-local bundle here would
    // cause a bad free once that deferred delete fires.
    auto* bundle = new image::Ktx1Bundle(data.data(), (uint32_t)data.size());
    // The constructor asserts on malformed input; we trust the file at this point.
    // srgb = true so the engine treats colors correctly for skybox/IBL.
    Texture* tex = ktxreader::Ktx1Reader::createTexture(engine, bundle, true);
    return tex;
}

FilamentIndirectLight* filament_createIndirectLightFromKTX(FilamentEngine* fe,
                                                            const char* ktxPath,
                                                            float intensity) {
    if (!fe || !fe->engine || !ktxPath) return nullptr;
    Texture* tex = loadCubemapKtx(fe->engine, ktxPath);
    if (!tex) return nullptr;
    IndirectLight* ibl = IndirectLight::Builder()
        .reflections(tex)
        .intensity(intensity)
        .build(*fe->engine);
    if (!ibl) {
        fe->engine->destroy(tex);
        return nullptr;
    }
    return (FilamentIndirectLight*)ibl;
}

FilamentIndirectLight* filament_createFlatIndirectLight(FilamentEngine* fe,
                                                         float r, float g, float b,
                                                         float intensity) {
    if (!fe || !fe->engine) return nullptr;
    // Band-1 (DC-term-only) spherical harmonics: a single coefficient that's
    // constant over the whole sphere of directions, i.e. genuinely uniform
    // ambient with no preferred direction — unlike a directional light, this
    // can't produce its own terminator/edge, so it's safe to add alongside
    // the sun without creating a second sharp lit/unlit divide.
    fmath::float3 sh[1] = { fmath::float3{r, g, b} };
    IndirectLight* ibl = IndirectLight::Builder()
        .irradiance(1, sh)
        .intensity(intensity)
        .build(*fe->engine);
    return (FilamentIndirectLight*)ibl;
}

void filament_setIndirectLight(FilamentScene* scene, FilamentIndirectLight* ibl) {
    if (!scene) return;
    ((Scene*)scene)->setIndirectLight((IndirectLight*)ibl);
}

void filament_destroyIndirectLight(FilamentEngine* fe, FilamentIndirectLight* ibl) {
    if (!fe || !fe->engine || !ibl) return;
    fe->engine->destroy((IndirectLight*)ibl);
    // The Swift side is responsible for nilling its pointer.
}

FilamentSkybox* filament_createSkyboxFromKTX(FilamentEngine* fe,
                                              const char* ktxPath) {
    if (!fe || !fe->engine || !ktxPath) return nullptr;
    Texture* tex = loadCubemapKtx(fe->engine, ktxPath);
    if (!tex) return nullptr;
    Skybox* sb = Skybox::Builder()
        .environment(tex)
        .showSun(true)
        .build(*fe->engine);
    if (!sb) {
        fe->engine->destroy(tex);
        return nullptr;
    }
    return (FilamentSkybox*)sb;
}

void filament_setSkybox(FilamentScene* scene, FilamentSkybox* skybox) {
    if (!scene) return;
    ((Scene*)scene)->setSkybox((Skybox*)skybox);
}

void filament_destroySkybox(FilamentEngine* fe, FilamentSkybox* skybox) {
    if (!fe || !fe->engine || !skybox) return;
    fe->engine->destroy((Skybox*)skybox);
    // The Swift side is responsible for nilling its pointer.
}
