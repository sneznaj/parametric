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

#include <vector>
#include <cmath>
#include <cstring>

// Embedded compiled PBR material
#include "studio_pbr_filamat.h"

using namespace filament;
// Use an alias for filament's math to avoid conflicts with simd:: from system headers.
namespace fmath = filament::math;

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
// Internal per-entity state
// ---------------------------------------------------------------------------

struct FilamentEntity {
    utils::Entity entity;
    VertexBuffer* vb = nullptr;
    IndexBuffer*  ib = nullptr;
    MaterialInstance* materialInstance = nullptr;
    Engine* engine = nullptr;
};

// ---------------------------------------------------------------------------
// Engine wrapper
// ---------------------------------------------------------------------------

struct FilamentEngine {
    Engine* engine = nullptr;
    Material* defaultMaterial = nullptr;
    void* metalDevice = nullptr;
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

    return fe;
}

void filament_destroyEngine(FilamentEngine* fe) {
    if (!fe) return;
    if (fe->defaultMaterial) {
        fe->engine->destroy(fe->defaultMaterial);
    }
    if (fe->engine) {
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
    // nativeWindow should be a CAMetalLayer* (preferred) or NSView*.
    // CAMetalLayer is thread-safe for this use; NSView is NOT because
    // Filament dispatches swap chain creation to the engine thread.
    if (!nativeWindow) {
        NSLog(@"FilamentBridge: createSwapChain called with null nativeWindow");
        return nullptr;
    }
    (void)viewPtr;
    return (FilamentSwapChain*)fe->engine->createSwapChain(nativeWindow);
}

void filament_resizeSwapChain(FilamentEngine* fe,
                              FilamentSwapChain* swapChain,
                              int width, int height) {
    (void)fe; (void)swapChain; (void)width; (void)height;
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

FilamentRenderer* filament_createRenderer(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    return (FilamentRenderer*)fe->engine->createRenderer();
}

bool filament_beginFrame(FilamentRenderer* renderer, FilamentSwapChain* swapChain) {
    if (!renderer || !swapChain) return false;
    return ((Renderer*)renderer)->beginFrame((SwapChain*)swapChain);
}

void filament_render(FilamentRenderer* renderer, FilamentView* view) {
    if (!renderer || !view) return;
    ((Renderer*)renderer)->render((View*)view);
}

void filament_endFrame(FilamentRenderer* renderer) {
    if (!renderer) return;
    ((Renderer*)renderer)->endFrame();
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

FilamentScene* filament_createScene(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    return (FilamentScene*)fe->engine->createScene();
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

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

FilamentView* filament_createView(FilamentEngine* fe) {
    if (!fe || !fe->engine) return nullptr;
    return (FilamentView*)fe->engine->createView();
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

void filament_viewSetClearColor(FilamentView* /*view*/, float r, float g, float b, float a) {
    // Clear color is set on the Renderer in Filament v1.72+.
    // We store this for later use when creating the renderer.
    (void)r; (void)g; (void)b; (void)a;
}

void filament_viewSetPostProcessing(FilamentView* view, bool enabled) {
    if (!view) return;
    ((View*)view)->setPostProcessingEnabled(enabled);
}

void filament_viewSetBloom(FilamentView* view, float intensity, float threshold) {
    if (!view || intensity <= 0.0f) return;
    auto* v = (View*)view;
    View::BloomOptions opts{};
    opts.enabled = true;
    opts.strength = intensity;
    opts.threshold = threshold;
    v->setBloomOptions(opts);
}

// ---------------------------------------------------------------------------
// Material
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

// ---------------------------------------------------------------------------
// Helper: create a default PBR material instance
// ---------------------------------------------------------------------------

static MaterialInstance* makePbrInstance(FilamentEngine* fe, FilamentMaterial* explicitMaterial) {
    Material* src = explicitMaterial ? (Material*)explicitMaterial : fe->defaultMaterial;
    if (!src) return nullptr;
    return src->createInstance();
}

static void applyPbrDefaults(MaterialInstance* mi) {
    if (!mi) return;
    mi->setParameter("baseColorFactor",     fmath::float4{0.72f, 0.72f, 0.78f, 1.0f});
    mi->setParameter("metallicFactor",      0.0f);
    mi->setParameter("roughnessFactor",     0.35f);
    mi->setParameter("reflectance",         0.5f);
    mi->setParameter("clearCoatFactor",     0.08f);
    mi->setParameter("clearCoatRoughness",  0.0f);
    mi->setParameter("anisotropy",          0.0f);
}

// ---------------------------------------------------------------------------
// Vertex format: position + tangent-quaternion (normal encoded) + UV
// ---------------------------------------------------------------------------

struct Vertex {
    fmath::float3 position;
    fmath::float4 tangentQ; // quaternion encoding normal/tangent frame
    fmath::float2 uv;
};

// ---------------------------------------------------------------------------
// Build a renderable from vertex/index data
// ---------------------------------------------------------------------------

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

    // Create vertex buffer with POSITION + TANGENTS + UV0.
    auto* vb = VertexBuffer::Builder()
        .vertexCount((uint32_t)vertices.size())
        .bufferCount(1)
        .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3,
                    offsetof(Vertex, position), sizeof(Vertex))
        .attribute(VertexAttribute::TANGENTS, 0, VertexBuffer::AttributeType::FLOAT4,
                    offsetof(Vertex, tangentQ), sizeof(Vertex))
        .attribute(VertexAttribute::UV0,     0, VertexBuffer::AttributeType::FLOAT2,
                    offsetof(Vertex, uv), sizeof(Vertex))
        .build(*engine);

    vb->setBufferAt(*engine, 0,
        VertexBuffer::BufferDescriptor(vertices.data(), vertices.size() * sizeof(Vertex)));

    // Create index buffer.
    auto* ib = IndexBuffer::Builder()
        .indexCount((uint32_t)indices.size())
        .bufferType(IndexBuffer::IndexType::UINT)
        .build(*engine);
    ib->setBuffer(*engine,
        IndexBuffer::BufferDescriptor(indices.data(), indices.size() * sizeof(uint32_t)));

    // Create material instance.
    MaterialInstance* mi = makePbrInstance(fe, material);
    if (!mi) {
        engine->destroy(vb);
        engine->destroy(ib);
        return nullptr;
    }
    applyPbrDefaults(mi);

    // Create entity.
    auto& em = utils::EntityManager::get();
    utils::Entity entity = em.create();

    RenderableManager::Builder(1)
        .boundingBox(Box().set(bbMin, bbMax))
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, vb, ib, 0, (uint32_t)indices.size())
        .material(0, mi)
        .culling(true)
        .build(*engine, entity);

    scn->addEntity(entity);

    auto* feEntity = new FilamentEntity();
    feEntity->entity = entity;
    feEntity->vb = vb;
    feEntity->ib = ib;
    feEntity->materialInstance = mi;
    feEntity->engine = engine;

    return (FilamentEntity*)feEntity;
}

void filament_removeEntity(FilamentScene* scene, FilamentEntity* entity) {
    if (!scene || !entity) return;
    auto* feEntity = (FilamentEntity*)entity;
    auto* scn = (Scene*)scene;

    scn->remove(feEntity->entity);

    if (feEntity->engine) {
        if (feEntity->vb) feEntity->engine->destroy(feEntity->vb);
        if (feEntity->ib) feEntity->engine->destroy(feEntity->ib);
        if (feEntity->materialInstance) feEntity->engine->destroy(feEntity->materialInstance);
    }

    auto& em = utils::EntityManager::get();
    em.destroy(feEntity->entity);
    delete feEntity;
}

void filament_entitySetTransform(FilamentEntity* entity, const float* matrix4x4) {
    (void)entity; (void)matrix4x4;
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
            Vertex v;
            v.position = fmath::float3{cx, cy, cz} + n * radius;
            v.tangentQ = normalToTangentQuat(n);
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
        indices.push_back(base); indices.push_back(base+1); indices.push_back(base+2);
        indices.push_back(base); indices.push_back(base+2); indices.push_back(base+3);
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
        fmath::float4 tq = normalToTangentQuat(n);
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

    // Side normals: pointing outward and slightly upward.
    float slopeLen = sqrtf(radius*radius + height*height);
    float nxScale = height / slopeLen;
    float nyScale = radius / slopeLen;

    for (int i = 0; i <= segments; i++) {
        float theta = 2.0f * (float)M_PI * (float)i / (float)segments;
        float x = cosf(theta), z = sinf(theta);
        fmath::float3 n{x * nxScale, nyScale, z * nxScale};
        n = normalize(n);
        fmath::float4 tq = normalToTangentQuat(n);
        float u = (float)i / (float)segments;
        verts.push_back({fmath::float3{cx + radius*x, botY, cz + radius*z}, tq, {u, 1}});
    }
    // Apex.
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

            Vertex v;
            v.position = fmath::float3{cx + px, cy + py, cz + pz};
            v.tangentQ = normalToTangentQuat(n);
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
        fmath::float4 tq = normalToTangentQuat(n);
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

    // Compute polygon normal.
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

    // Compute centroid for caps.
    fmath::float3 centroid{0,0,0};
    for (auto& p : poly) centroid = centroid + p;
    centroid = centroid / (float)count;

    // Top face.
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

    // Bottom face.
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

    // Side walls.
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

    // Bounds.
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
        fmath::float3 n = fmath::float3{0, 1, 0};
        n = normalize(n);
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
    return (FilamentEntity*)ent;
}

// ---------------------------------------------------------------------------
// IBL / Skybox (not yet implemented — directional lights are sufficient)
// ---------------------------------------------------------------------------

FilamentIndirectLight* filament_createIndirectLight(FilamentEngine* fe,
                                                    const void* hdrData, size_t size,
                                                    float intensity) {
    (void)fe; (void)hdrData; (void)size; (void)intensity;
    return nullptr;
}

void filament_setIndirectLight(FilamentScene* scene, FilamentIndirectLight* ibl) {
    if (scene && ibl) {
        ((Scene*)scene)->setIndirectLight((IndirectLight*)ibl);
    }
}

FilamentSkybox* filament_createSkybox(FilamentEngine* fe,
                                      const void* hdrData, size_t size) {
    (void)fe; (void)hdrData; (void)size;
    return nullptr;
}

void filament_setSkybox(FilamentScene* scene, FilamentSkybox* skybox) {
    (void)scene; (void)skybox;
}
