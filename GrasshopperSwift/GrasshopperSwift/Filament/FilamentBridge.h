// FilamentBridge.h
// C-compatible bridge to Google Filament rendering engine for use from Swift.
// All Filament C++ objects are held behind opaque pointers.

#ifndef FilamentBridge_h
#define FilamentBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque handle types
// ---------------------------------------------------------------------------
typedef struct FilamentEngine       FilamentEngine;
typedef struct FilamentScene        FilamentScene;
typedef struct FilamentView         FilamentView;
typedef struct FilamentRenderer     FilamentRenderer;
typedef struct FilamentCamera       FilamentCamera;
typedef struct FilamentSwapChain    FilamentSwapChain;
typedef struct FilamentMaterial     FilamentMaterial;
typedef struct FilamentEntity       FilamentEntity;
typedef struct FilamentTexture      FilamentTexture;
typedef struct FilamentIndirectLight FilamentIndirectLight;
typedef struct FilamentSkybox       FilamentSkybox;
typedef struct FilamentColorGrading FilamentColorGrading;

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

/// Create a Filament engine with the Metal backend.
/// Returns NULL on failure.
FilamentEngine* filament_createEngine(void);

/// Destroy the engine and the default material. All other Filament resources
/// (views, scenes, cameras, renderers, swap chains, IBL, skyboxes, color grading,
/// entities, material instances) MUST be explicitly destroyed before calling this.
void filament_destroyEngine(FilamentEngine* engine);

// ---------------------------------------------------------------------------
// Swap chain (from an NSView)
// ---------------------------------------------------------------------------

/// Create a swap chain backed by the given CAMetalLayer (preferred) or NSView.
FilamentSwapChain* filament_createSwapChain(FilamentEngine* engine,
                                            void* nativeWindow,
                                            uint64_t viewPtr);

/// Notify Filament that the swap chain surface has resized.
void filament_resizeSwapChain(FilamentEngine* engine,
                              FilamentSwapChain* swapChain,
                              int width, int height);

/// Destroy a swap chain. Must be called before the engine is destroyed.
void filament_destroySwapChain(FilamentEngine* engine, FilamentSwapChain* swapChain);

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

FilamentRenderer* filament_createRenderer(FilamentEngine* engine);

/// Begin a frame. Returns true if rendering should proceed.
bool filament_beginFrame(FilamentRenderer* renderer,
                         FilamentSwapChain* swapChain);

/// Render a view.
void filament_render(FilamentRenderer* renderer, FilamentView* view);

/// End the frame.
void filament_endFrame(FilamentRenderer* renderer);

/// Set clear color and clear-on-begin behavior.
/// Color values are linear-RGB in [0, 1].
void filament_rendererSetClearColor(FilamentRenderer* renderer,
                                    float r, float g, float b, float a);

/// Set whether the renderer should clear the SwapChain each frame.
void filament_rendererSetClear(FilamentRenderer* renderer, bool enabled);

/// Destroy a renderer. Must be called before the engine is destroyed.
void filament_destroyRenderer(FilamentEngine* engine, FilamentRenderer* renderer);

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

FilamentScene* filament_createScene(FilamentEngine* engine);

/// Destroy a scene. Must be called before the engine is destroyed.
void filament_destroyScene(FilamentEngine* engine, FilamentScene* scene);

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

FilamentCamera* filament_createCamera(FilamentEngine* engine);

/// Position the camera. All parameters in world-space.
void filament_cameraLookAt(FilamentCamera* camera,
                           float eyeX, float eyeY, float eyeZ,
                           float centerX, float centerY, float centerZ,
                           float upX, float upY, float upZ);

/// Set perspective projection. fovInDegrees is the vertical field of view.
void filament_cameraSetPerspective(FilamentCamera* camera,
                                   float fovInDegrees,
                                   float aspect,
                                   float nearPlane,
                                   float farPlane);

/// Convenience: orbit camera around a target point.
void filament_cameraOrbit(FilamentCamera* camera,
                          float theta, float phi, float radius,
                          float targetX, float targetY, float targetZ);

/// Set physical camera exposure (aperture f-stops, shutter seconds, ISO sensitivity).
void filament_cameraSetExposurePhysical(FilamentCamera* camera,
                                        float aperture,
                                        float shutterSpeed,
                                        float sensitivity);

/// Set exposure directly in EV100 stops. Equivalent to photometric "scene luminance" model.
void filament_cameraSetExposureDirect(FilamentCamera* camera, float ev100);

// ---------------------------------------------------------------------------
// View (ties scene + camera + viewport together)
// ---------------------------------------------------------------------------

FilamentView* filament_createView(FilamentEngine* engine);
void filament_viewSetScene(FilamentView* view, FilamentScene* scene);
void filament_viewSetCamera(FilamentView* view, FilamentCamera* camera);
void filament_viewSetViewport(FilamentView* view, int x, int y, int width, int height);

/// Enable or disable post-processing (tone mapping). Enabled by default in cinematic mode.
void filament_viewSetPostProcessing(FilamentView* view, bool enabled);

/// Destroy a view. Must be called before the engine is destroyed.
void filament_destroyView(FilamentEngine* engine, FilamentView* view);

// ---------------------------------------------------------------------------
// Bloom / SSAO / fog / vignette / dithering / AA / shadows
// ---------------------------------------------------------------------------

typedef struct FilamentBloomOptions {
    bool   enabled;
    float  strength;
    float  threshold;        // luminance threshold; pixels above this bloom
    float  anamorphism;      // 0 = isotropic, 1 = wide horizontal/vertical anamorphism
    int    levels;           // number of blur levels (1-11)
    float  blendMode;        // 0 = additive, 1 = interpolate
} FilamentBloomOptions;

void filament_viewSetBloomOptions(FilamentView* view, FilamentBloomOptions options);

typedef struct FilamentAmbientOcclusionOptions {
    bool  enabled;
    float radius;            // world-space radius
    float power;             // darkness exponent
    float bias;              // depth bias to avoid self-occlusion
    float intensity;         // scalar
    int   quality;           // 0=LOW, 1=MEDIUM, 2=HIGH, 3=ULTRA
    // Bent-normal specular occlusion: a more accurate energy-conservation
    // term for how much of the *specular* (not just diffuse) IBL response a
    // crevice occludes — without it, specular ambient occlusion falls back
    // to a cruder "Simple" approximation baked into the material. Costs an
    // extra buffer + normal-bending pass, so it's a real quality/perf lever.
    bool  bentNormals;
} FilamentAmbientOcclusionOptions;

void filament_viewSetAmbientOcclusionOptions(FilamentView* view,
                                             FilamentAmbientOcclusionOptions options);

typedef struct FilamentFogOptions {
    bool   enabled;
    float  distance;         // world-space distance at which fog starts
    float  height;           // world-space height at which fog density = density
    float  heightFalloff;    // 0 = uniform, 1 = fall off at height
    float  density;          // [0, 1]
    float  inScatteringStart;
    float  inScatteringEnd;
    bool   fogColorFromIbl;
    float  r, g, b;          // linear color when fogColorFromIbl is false
} FilamentFogOptions;

void filament_viewSetFogOptions(FilamentView* view, FilamentFogOptions options);

typedef struct FilamentVignetteOptions {
    bool   enabled;
    float  midPoint;         // luminance at which vignette starts
    float  radius;           // extent of darkening
    float  blend;            // [0, 1]
} FilamentVignetteOptions;

void filament_viewSetVignetteOptions(FilamentView* view, FilamentVignetteOptions options);

/// Dithering mode. 0=NONE, 1=TEMPORAL, 2=MIN, 3=MAX. TEMPORAL masks banding best.
void filament_viewSetDithering(FilamentView* view, int mode);

/// Anti-aliasing mode. Bitmask: 0=NONE, 1=FXAA, 2=TAA.
void filament_viewSetAntiAliasing(FilamentView* view, int mode);

typedef struct FilamentTemporalAntiAliasingOptions {
    bool  enabled;
    float filterWidth;
    float historyWeight;     // 0 = trust current frame, 1 = trust history fully
    bool  upscaling;         // enables TAA upscaling (cheaper but lower-quality)
    bool  varianceFilter;    // reduces ghosting on edges
} FilamentTemporalAntiAliasingOptions;

void filament_viewSetTemporalAntiAliasingOptions(FilamentView* view,
                                                 FilamentTemporalAntiAliasingOptions options);

typedef struct FilamentMultiSampleAntiAliasingOptions {
    bool enabled;
    int  sampleCount;        // 1 = off, typically 2/4/8 depending on GPU support
    bool customResolve;      // higher-quality (costlier) resolve for HDR scenes
} FilamentMultiSampleAntiAliasingOptions;

/// True hardware multi-sample anti-aliasing (distinct from the FXAA/TAA
/// post-process `filament_viewSetAntiAliasing` mode above — this resolves
/// geometric edges at the rasterizer, the other smooths the final image).
void filament_viewSetMultiSampleAntiAliasingOptions(FilamentView* view,
                                                    FilamentMultiSampleAntiAliasingOptions options);

typedef struct FilamentDynamicResolutionOptions {
    bool  enabled;
    bool  homogeneousScaling;
    float minScaleX, minScaleY;   // lowest resolution scale used to hit the target frame rate
    float maxScaleX, maxScaleY;   // highest resolution scale (e.g. supersampling on fast GPUs)
    float sharpness;              // upscale sharpening, [0, 1]
    int   quality;                // upscaling quality: 0=LOW, 1=MEDIUM, 2=HIGH, 3=ULTRA
} FilamentDynamicResolutionOptions;

/// Render at a lower resolution and upscale when the frame is taking too
/// long, or supersample when there's headroom. This is the render-*resolution*
/// lever in the adaptive quality system — distinct from the fixed-cost
/// per-pixel effects (SSAO/bloom/shadows) toggled elsewhere.
void filament_viewSetDynamicResolutionOptions(FilamentView* view,
                                              FilamentDynamicResolutionOptions options);

/// HDR color buffer precision: 0=LOW/MEDIUM uses a packed R11G11B10F buffer,
/// 1=HIGH/ULTRA uses a full RGB16F buffer (more highlight/shadow headroom
/// before banding, at extra bandwidth cost). Maps to Filament's
/// View::RenderQuality::hdrColorBuffer.
void filament_viewSetHdrColorBufferQuality(FilamentView* view, int quality);

/// Shadow type. 0=PCF, 1=VSM, 2=DPCF, 3=PCSS, 4=PCFd. VSM gives softer photographic shadows.
void filament_viewSetShadowType(FilamentView* view, int shadowType);

/// Globally enable or disable shadow mapping. Lights must also opt in with castShadows=true.
void filament_viewSetShadowingEnabled(FilamentView* view, bool enabled);

/// Apply a ColorGrading pipeline (exposure / white balance / contrast / saturation / tone-mapping).
/// Pass NULL to disable.
void filament_viewSetColorGrading(FilamentView* view, FilamentColorGrading* grading);

// ---------------------------------------------------------------------------
// ColorGrading builder
// ---------------------------------------------------------------------------

FilamentColorGrading* filament_createColorGrading(FilamentEngine* engine,
                                                  float exposure,        // EV stops
                                                  float whiteBalanceKelvin,
                                                  float contrast,        // [-1, 1]
                                                  float saturation,      // [-1, 1]
                                                  int   toneMapper,      // 0=LINEAR, 1=ACES, 2=ACES_LEGACY, 3=FILMIC, 4=PBR_NEUTRAL, 5=AGX
                                                  float shadowGamma,
                                                  float midPoint,
                                                  float highlightGamma);

void filament_destroyColorGrading(FilamentEngine* engine, FilamentColorGrading* grading);

// ---------------------------------------------------------------------------
// Material & Material Instance
// ---------------------------------------------------------------------------

FilamentMaterial* filament_loadMaterial(FilamentEngine* engine,
                                        const void* data, size_t size);

FilamentMaterial* filament_createMaterialInstance(FilamentMaterial* material);

/// Create a MaterialInstance from the engine's built-in studio PBR material.
/// This is the normal way to get an instance to configure and pass into the
/// `filament_create*` geometry functions below — the instance you build here
/// is attached directly to the renderable(s), so one instance can (and, via
/// the Swift-side material cache, usually does) back many shapes at once.
FilamentMaterial* filament_createDefaultMaterialInstance(FilamentEngine* engine);

/// Create a MaterialInstance from the engine's built-in subsurface-scattering
/// material (studio_subsurface.mat, shadingModel: subsurface) — used for
/// translucent presets (wax, marble, alabaster) instead of the metallic-
/// roughness `filament_createDefaultMaterialInstance`. Its parameter set is
/// different (baseColorFactor, metallicFactor, roughnessFactor, reflectance,
/// subsurfacePower, subsurfaceColorFactor, thicknessFactor, normalDetail,
/// roughnessVariation, textureScale, roughnessPattern) — no clearCoat/
/// anisotropy/sheen, which don't exist on this shading model.
FilamentMaterial* filament_createSubsurfaceMaterialInstance(FilamentEngine* engine);

/// Destroy a MaterialInstance created via filament_createDefaultMaterialInstance
/// or filament_createMaterialInstance. Must be called before the engine is
/// destroyed, and only after every entity referencing it has been removed
/// from the scene (filament_removeEntity does NOT destroy shared instances —
/// see its doc comment).
void filament_engineDestroyMaterialInstance(FilamentEngine* engine, FilamentMaterial* instance);

void filament_materialSetFloat(FilamentMaterial* material,
                               const char* name, float value);
void filament_materialSetFloat2(FilamentMaterial* material,
                                const char* name, float x, float y);
void filament_materialSetFloat3(FilamentMaterial* material,
                                const char* name, float x, float y, float z);
void filament_materialSetFloat4(FilamentMaterial* material,
                                const char* name, float x, float y, float z, float w);

void filament_destroyMaterial(FilamentMaterial* material);

/// Destroy a material via the engine. Must be called before the engine is destroyed
/// and after all entities referencing it have been removed from the scene.
void filament_engineDestroyMaterial(FilamentEngine* engine, FilamentMaterial* material);

// ---------------------------------------------------------------------------
// Procedural geometry
// ---------------------------------------------------------------------------

FilamentEntity* filament_createSphere(FilamentEngine* engine, FilamentScene* scene,
                                      FilamentMaterial* material,
                                      float cx, float cy, float cz,
                                      float radius, int segments);

FilamentEntity* filament_createBox(FilamentEngine* engine, FilamentScene* scene,
                                   FilamentMaterial* material,
                                   float minX, float minY, float minZ,
                                   float maxX, float maxY, float maxZ);

FilamentEntity* filament_createCylinder(FilamentEngine* engine, FilamentScene* scene,
                                        FilamentMaterial* material,
                                        float cx, float cy, float cz,
                                        float radius, float height, int segments);

FilamentEntity* filament_createCone(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float cx, float cy, float cz,
                                    float radius, float height, int segments);

FilamentEntity* filament_createTorus(FilamentEngine* engine, FilamentScene* scene,
                                     FilamentMaterial* material,
                                     float cx, float cy, float cz,
                                     float majorRadius, float minorRadius,
                                     int majorSegments, int minorSegments);

FilamentEntity* filament_createDisc(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float cx, float cy, float cz,
                                    float radius, int segments);

FilamentEntity* filament_createPlane(FilamentEngine* engine, FilamentScene* scene,
                                     FilamentMaterial* material,
                                     float cx, float cy, float cz,
                                     float width, float depth);

FilamentEntity* filament_createLine(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float x0, float y0, float z0,
                                    float x1, float y1, float z1,
                                    float radius);

FilamentEntity* filament_createPolygon(FilamentEngine* engine, FilamentScene* scene,
                                       FilamentMaterial* material,
                                       const float* points, int count,
                                       float extrusion);

FilamentEntity* filament_createSurfaceStrip(FilamentEngine* engine, FilamentScene* scene,
                                            FilamentMaterial* material,
                                            const float* curveA, int countA,
                                            const float* curveB, int countB);

/// Generic indexed triangle mesh. `positions`/`normals` are flat xyz float
/// arrays of length vertexCount*3; `indices` is a flat triangle index list
/// (length indexCount, a multiple of 3, CCW winding). Backs the app's
/// general-purpose `.mesh` geometry case (extrude/revolve/sweep/boolean
/// results) that don't fit the other fixed-parameter primitives above.
FilamentEntity* filament_createMesh(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    const float* positions, const float* normals, int vertexCount,
                                    const uint32_t* indices, int indexCount);

/// Remove an entity from the scene and destroy its VB/IB. The material
/// instance passed in when the entity was created is normally *shared*
/// (cached per-material on the Swift side across many shapes), so it is
/// intentionally NOT destroyed here — destroy shared instances yourself via
/// filament_engineDestroyMaterialInstance once nothing references them
/// anymore (e.g. at teardown).
void filament_removeEntity(FilamentScene* scene, FilamentEntity* entity);

/// Set the local-to-world transform for an entity as a column-major 4x4 matrix.
void filament_entitySetTransform(FilamentEntity* entity, const float* matrix4x4);

/// Get the current world-space transform for an entity (writes 16 floats to outMatrix).
void filament_entityGetTransform(FilamentEntity* entity, float* outMatrix);

// ---------------------------------------------------------------------------
// Lights
// ---------------------------------------------------------------------------

FilamentEntity* filament_createDirectionalLight(FilamentEngine* engine,
                                                FilamentScene* scene,
                                                float dirX, float dirY, float dirZ,
                                                float r, float g, float b,
                                                float intensity,
                                                bool castsShadows);

FilamentEntity* filament_createPointLight(FilamentEngine* engine,
                                          FilamentScene* scene,
                                          float posX, float posY, float posZ,
                                          float r, float g, float b,
                                          float intensity);

FilamentEntity* filament_createSpotLight(FilamentEngine* engine,
                                         FilamentScene* scene,
                                         float posX, float posY, float posZ,
                                         float dirX, float dirY, float dirZ,
                                         float r, float g, float b,
                                         float intensity,
                                         float coneInner,
                                         float coneOuter);

/// Update a directional light's direction, color, intensity, shadow flag.
void filament_lightUpdateDirectional(FilamentEntity* light,
                                     float dirX, float dirY, float dirZ,
                                     float r, float g, float b,
                                     float intensity,
                                     bool castsShadows);

// ---------------------------------------------------------------------------
// Indirect light / IBL
// ---------------------------------------------------------------------------

/// Create an indirect light from a pre-filtered .ktx file (Filament IBL format).
/// `ktxPath` must be a UTF-8 file system path. Returns NULL on failure.
FilamentIndirectLight* filament_createIndirectLightFromKTX(FilamentEngine* engine,
                                                            const char* ktxPath,
                                                            float intensity);

/// Create a uniform (direction-less) ambient indirect light from a flat
/// color — a DC-only (band 1) spherical-harmonics irradiance, so it lights
/// every surface normal equally instead of falling off toward any single
/// direction. Used as the fallback fill when the bundled IBL/skybox .ktx
/// assets fail to load, so geometry still gets a soft ambient wraparound
/// instead of no fill (or, worse, a second hard-edged directional light,
/// which just creates its own sharp terminator instead of a real ambient
/// term). Returns NULL on failure.
FilamentIndirectLight* filament_createFlatIndirectLight(FilamentEngine* engine,
                                                         float r, float g, float b,
                                                         float intensity);

void filament_setIndirectLight(FilamentScene* scene, FilamentIndirectLight* ibl);

/// Destroy an indirect light. Must be called before the engine is destroyed.
void filament_destroyIndirectLight(FilamentEngine* engine, FilamentIndirectLight* ibl);

// ---------------------------------------------------------------------------
// Skybox
// ---------------------------------------------------------------------------

/// Create a skybox from a Filament skybox .ktx file.
FilamentSkybox* filament_createSkyboxFromKTX(FilamentEngine* engine,
                                              const char* ktxPath);

void filament_setSkybox(FilamentScene* scene, FilamentSkybox* skybox);

/// Destroy a skybox. Must be called before the engine is destroyed.
void filament_destroySkybox(FilamentEngine* engine, FilamentSkybox* skybox);

#ifdef __cplusplus
}
#endif

#endif /* FilamentBridge_h */
