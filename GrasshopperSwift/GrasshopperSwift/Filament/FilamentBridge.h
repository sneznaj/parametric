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

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

/// Create a Filament engine with the Metal backend.
/// Returns NULL on failure.
FilamentEngine* filament_createEngine(void);

/// Destroy the engine and all associated resources.
void filament_destroyEngine(FilamentEngine* engine);

// ---------------------------------------------------------------------------
// Swap chain (from an NSView)
// ---------------------------------------------------------------------------

/// Create a swap chain backed by the given NSView.
/// `nsView` is a pointer to the NSView (bridged as UnsafeMutableRawPointer from Swift).
FilamentSwapChain* filament_createSwapChain(FilamentEngine* engine,
                                            void* nsView,
                                            uint64_t viewPtr);

/// Notify Filament that the swap chain surface has resized.
void filament_resizeSwapChain(FilamentEngine* engine,
                              FilamentSwapChain* swapChain,
                              int width, int height);

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

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

FilamentScene* filament_createScene(FilamentEngine* engine);

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
                          float theta,      // azimuthal angle in radians
                          float phi,        // polar angle in radians
                          float radius,     // distance from target
                          float targetX, float targetY, float targetZ);

// ---------------------------------------------------------------------------
// View (ties scene + camera + viewport together)
// ---------------------------------------------------------------------------

FilamentView* filament_createView(FilamentEngine* engine);
void filament_viewSetScene(FilamentView* view, FilamentScene* scene);
void filament_viewSetCamera(FilamentView* view, FilamentCamera* camera);
void filament_viewSetViewport(FilamentView* view, int x, int y, int width, int height);

/// Set the view's background color (linear RGB).
void filament_viewSetClearColor(FilamentView* view, float r, float g, float b, float a);

/// Enable or disable post-processing (bloom, tone mapping). Disabled by default.
void filament_viewSetPostProcessing(FilamentView* view, bool enabled);

/// Set bloom intensity (0..1). Requires post-processing enabled.
void filament_viewSetBloom(FilamentView* view, float intensity, float threshold);

// ---------------------------------------------------------------------------
// Material & Material Instance
// ---------------------------------------------------------------------------

/// Load a material from a compiled .filamat blob in memory.
FilamentMaterial* filament_loadMaterial(FilamentEngine* engine,
                                        const void* data, size_t size);

/// Create a material instance from a material.
FilamentMaterial* filament_createMaterialInstance(FilamentMaterial* material);

/// Set a float parameter on the material instance by name.
void filament_materialSetFloat(FilamentMaterial* material,
                               const char* name, float value);

/// Set a float2 parameter.
void filament_materialSetFloat2(FilamentMaterial* material,
                                const char* name, float x, float y);

/// Set a float3 parameter.
void filament_materialSetFloat3(FilamentMaterial* material,
                                const char* name, float x, float y, float z);

/// Set a float4 parameter.
void filament_materialSetFloat4(FilamentMaterial* material,
                                const char* name, float x, float y, float z, float w);

/// Destroy a material (or material instance).
void filament_destroyMaterial(FilamentMaterial* material);

// ---------------------------------------------------------------------------
// Procedural geometry
// ---------------------------------------------------------------------------

/// Each geometry function creates a renderable entity in the scene.
/// Returns an opaque handle. Pass NULL for material to use a default gray PBR.
/// Coordinates use the same convention as the existing app: Y-up.

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

/// A thin disc in the XZ plane (Y-up coordinate system).
FilamentEntity* filament_createDisc(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float cx, float cy, float cz,
                                    float radius, int segments);

/// A flat plane in the XZ plane at the given Y height.
FilamentEntity* filament_createPlane(FilamentEngine* engine, FilamentScene* scene,
                                     FilamentMaterial* material,
                                     float cx, float cy, float cz,
                                     float width, float depth);

/// A thin oriented cylinder between two points (suitable for wire-like lines).
FilamentEntity* filament_createLine(FilamentEngine* engine, FilamentScene* scene,
                                    FilamentMaterial* material,
                                    float x0, float y0, float z0,
                                    float x1, float y1, float z1,
                                    float radius);

/// Extruded polygon. `points` is an array of (x,y,z) triplets, `count` is the number of vertices.
/// Extrudes by `extrusion` amount along the polygon's normal.
FilamentEntity* filament_createPolygon(FilamentEngine* engine, FilamentScene* scene,
                                       FilamentMaterial* material,
                                       const float* points, int count,
                                       float extrusion);

/// Surface strip (loft) between two curves. curveA and curveB are each arrays of (x,y,z) triplets.
FilamentEntity* filament_createSurfaceStrip(FilamentEngine* engine, FilamentScene* scene,
                                            FilamentMaterial* material,
                                            const float* curveA, int countA,
                                            const float* curveB, int countB);

/// Remove an entity from the scene and destroy it.
void filament_removeEntity(FilamentScene* scene, FilamentEntity* entity);

/// Set the local-to-world transform for an entity as a column-major 4x4 matrix.
void filament_entitySetTransform(FilamentEntity* entity, const float* matrix4x4);

// ---------------------------------------------------------------------------
// Lights
// ---------------------------------------------------------------------------

/// Create a directional (sun) light.
FilamentEntity* filament_createDirectionalLight(FilamentEngine* engine,
                                                FilamentScene* scene,
                                                float dirX, float dirY, float dirZ,
                                                float r, float g, float b,
                                                float intensity,
                                                bool castsShadows);

/// Create a point (omni) light.
FilamentEntity* filament_createPointLight(FilamentEngine* engine,
                                          FilamentScene* scene,
                                          float posX, float posY, float posZ,
                                          float r, float g, float b,
                                          float intensity);

/// Create a spot light.
FilamentEntity* filament_createSpotLight(FilamentEngine* engine,
                                         FilamentScene* scene,
                                         float posX, float posY, float posZ,
                                         float dirX, float dirY, float dirZ,
                                         float r, float g, float b,
                                         float intensity,
                                         float coneInner,  // inner cone angle in radians
                                         float coneOuter); // outer cone angle in radians

// ---------------------------------------------------------------------------
// Indirect light / IBL
// ---------------------------------------------------------------------------

/// Create an indirect light from an HDR equirectangular environment map (binary data + size).
/// The data should be RGBE (.hdr) or RGB16F format.
FilamentIndirectLight* filament_createIndirectLight(FilamentEngine* engine,
                                                    const void* hdrData, size_t size,
                                                    float intensity);

/// Set the indirect light on a scene.
void filament_setIndirectLight(FilamentScene* scene, FilamentIndirectLight* ibl);

// ---------------------------------------------------------------------------
// Skybox
// ---------------------------------------------------------------------------

/// Create a skybox from an HDR equirectangular environment map.
FilamentSkybox* filament_createSkybox(FilamentEngine* engine,
                                      const void* hdrData, size_t size);

/// Set the skybox on a scene.
void filament_setSkybox(FilamentScene* scene, FilamentSkybox* skybox);

#ifdef __cplusplus
}
#endif

#endif /* FilamentBridge_h */
