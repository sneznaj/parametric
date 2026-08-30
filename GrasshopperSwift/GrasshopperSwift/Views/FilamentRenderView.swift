import SwiftUI
import MetalKit
import QuartzCore

// MARK: - Cinematic Defaults

/// Default cinematic RenderConfig used when the graph doesn't override anything.
private let kCinematicDefaultConfig = RenderConfig.cinematicDefault

// MARK: - Filament Host View

/// Custom NSView that hosts the Filament renderer via a CAMetalLayer.
/// Configured for cinematic PBR: HDR pixel format, image-based lighting,
/// bloom, SSAO, TAA, ACES tone mapping, soft shadows, and per-shape materials.
final class FilamentHostView: NSView {

    // Filament bridge objects
    private var engine: OpaquePointer?
    private var swapChain: OpaquePointer?
    private var renderer: OpaquePointer?
    private var scene: OpaquePointer?
    private var camera: OpaquePointer?
    private var filamentView: OpaquePointer?

    // Cinematic resources
    private var iblTexture: OpaquePointer?
    private var skyboxTexture: OpaquePointer?
    private var colorGrading: OpaquePointer?
    private var sunLight: OpaquePointer?
    private var pointLightEntities: [OpaquePointer] = []  // one per RenderConfig.pointLights entry

    // Material instance cache: shared across shapes whose materials are the same
    // (or mathematically-connected near-duplicates — see Material3D.RenderKey)
    // so they render as one connected material instance instead of duplicates.
    private var materialInstanceCache: [Material3D.RenderKey: OpaquePointer] = [:]

    // Tracked entities for cleanup. Phase A: full rebuild on each populate().
    // Phase B will turn this into an entity-diff map keyed by TrackedShape.id.
    private var entities: [OpaquePointer] = []

    // Phase B: entity-diff maps keyed by TrackedShape.id.
    private var entitiesByID: [UUID: OpaquePointer] = [:]
    private var shapesByID: [UUID: GeometricShape] = [:]

    // SwiftUI calls update(trackedShapes:renderConfig:) as soon as this view
    // is inserted into the hierarchy — typically before viewDidMoveToWindow
    // has had a chance to run setupFilament() and flip filamentSetupDone.
    // That first call used to just bail out via the guard below and be lost:
    // if the graph's shapes/config don't change again afterward, SwiftUI has
    // no reason to call updateNSView a second time, so the scene stayed
    // permanently empty (sky/ground only, no actual geometry) with no error.
    // Cache the latest call here and replay it once setup finishes.
    private var pendingTrackedShapes: [TrackedShape]?
    private var pendingRenderConfig: RenderConfig?

    // The last RenderConfig applied. Skips redundant bridge calls.
    private var lastAppliedConfig: RenderConfig?

    // Orbit camera state
    private var cameraTheta: Float = 0.7      // azimuthal angle (radians)
    private var cameraPhi: Float = 0.5        // polar angle (radians)
    private var cameraRadius: Float = 25.0     // distance from target
    private var cameraTarget: (Float, Float, Float) = (0, 0, 0)

    // Realistic-mode drag target. Viewport orbit leaves scene entities and
    // lights untouched; Object mode rotates only the rendered entities.
    private var interactionMode: RealisticInteractionMode = .viewport
    private var objectYaw: Float = 0
    private var objectPitch: Float = 0

    // Scene-scale reference (the shapes' bounding-box diagonal, set by
    // autoFrame). Zoom clamp bounds below are relative to this — a fixed
    // absolute clamp (e.g. capping cameraRadius at 200) silently overrides
    // whatever distance autoFrame legitimately computed for scenes bigger
    // than that, so the very first scroll/pinch after auto-framing would
    // snap the camera far closer than the scene needs, with no way to
    // scroll back out past the cap. Grasshopper-style parametric geometry
    // can be any scale, so the clamp has to track the scene, not a constant.
    private var sceneDiag: Float = 10.0

    // Mouse tracking
    private var isDragging = false
    private var lastDragPoint: CGPoint = .zero

    // Main-thread render timer (avoiding CVDisplayLink threading issues)
    private var renderTimer: DispatchSourceTimer?
    private var renderTimerActive = false

    // Adaptive graphics quality: samples how long each frame's beginFrame/
    // render/endFrame call takes and steps the post-processing/AA/shadow/
    // resolution bundle up or down to match this Mac's actual performance.
    // See GraphicsQualityController and applyQualityTier(_:view:) below.
    private let qualityController = GraphicsQualityController.shared
    private var appliedQualityTier: GraphicsQualityTier?

    // Cached viewport size (updated on main thread only)
    private var cachedWidth: Int32 = 800
    private var cachedHeight: Int32 = 600
    private var cachedScale: CGFloat = 2.0

    // Track whether Filament has been set up (deferred until in window)
    private var filamentSetupDone = false

    // Strongly-held Metal layer. Engine::createSwapChain() is fire-and-forget: it
    // returns on the main thread but the real MetalSwapChain is constructed later
    // on Filament's engine thread (FEngine::loop). Filament retains the layer
    // *itself* — but only when that deferred construction runs. If the layer has
    // been released by then (SwiftUI/AppKit tearing down or churning this view),
    // MetalSwapChain's `isKindOfClass:[CAMetalLayer]` check hits freed memory and
    // panics → std::terminate → abort(). Holding a strong reference here keeps the
    // layer alive across that async window and through Engine::destroy's drain.
    private var metalLayer: CAMetalLayer?

    // MARK: - Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ensureMetalLayer()
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        ensureMetalLayer()
        return metalLayer!
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !filamentSetupDone {
            filamentSetupDone = true
            setupFilament()
            startRenderLoop()
            if let shapes = pendingTrackedShapes, let config = pendingRenderConfig {
                pendingTrackedShapes = nil
                pendingRenderConfig = nil
                update(trackedShapes: shapes, renderConfig: config, interactionMode: interactionMode)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            cachedScale = scale
        }
    }

    deinit {
        stopRenderLoop()
        teardownFilament()
    }

    // MARK: - Metal Layer

    /// Create (once) and configure the CAMetalLayer, retaining it strongly via
    /// `metalLayer` so its lifetime outlives Filament's deferred swap-chain setup.
    private func ensureMetalLayer() {
        let l: CAMetalLayer
        if let existing = metalLayer {
            l = existing
        } else {
            l = CAMetalLayer()
            metalLayer = l
            if layer == nil { layer = l }
        }
        configure(metalLayer: l)
    }

    /// Configure the Metal layer for HDR. Filament writes a wide-range color
    /// buffer here; downstream compositing must be aware.
    private func configure(metalLayer l: CAMetalLayer) {
        l.device = MTLCreateSystemDefaultDevice()
        // HDR pixel format — wider range so bloom + tone mapping have headroom.
        // AppKit compositing will downconvert to sRGB at presentation time.
        l.pixelFormat = .rgba16Float
        l.framebufferOnly = false
        l.isOpaque = true
        l.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: - Filament Setup

    private func setupFilament() {
        engine = filament_createEngine()
        guard let eng = engine else {
            print("FilamentRenderView: failed to create Filament engine")
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        var size = bounds.size
        if size.width < 1 { size.width = 800 }
        if size.height < 1 { size.height = 800 }
        guard let metalLayer = metalLayer else {
            print("FilamentRenderView: no Metal layer")
            return
        }
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)

        if metalLayer.device == nil {
            metalLayer.device = MTLCreateSystemDefaultDevice()
        }

        swapChain = filament_createSwapChain(eng,
            Unmanaged.passUnretained(metalLayer).toOpaque(), 0)

        renderer = filament_createRenderer(eng)
        scene = filament_createScene(eng)
        camera = filament_createCamera(eng)
        filamentView = filament_createView(eng)

        guard let scn = scene,
              let cam = camera,
              let fv = filamentView,
              let rend = renderer,
              let sw = swapChain else {
            print("FilamentRenderView: failed to create Filament components")
            return
        }

        // Clear color — a near-black tint. With a skybox this is rarely visible,
        // but it's the fallback when no IBL assets are bundled.
        filament_rendererSetClearColor(rend, 0.04, 0.04, 0.06, 1.0)
        filament_rendererSetClear(rend, true)

        filament_viewSetScene(fv, scn)
        filament_viewSetCamera(fv, cam)
        filament_viewSetViewport(fv, 0, 0, cachedWidth, cachedHeight)

        // Post-processing pipeline enabled — drives bloom, SSAO, TAA, color grading.
        filament_viewSetPostProcessing(fv, true)

        // IBL & skybox — load the bundled studio-sky .ktx files from the app
        // bundle. If absent, fall back to a soft synthetic fill light.
        let hasIBL = loadIBLIfAvailable(engine: eng, scene: scn)

        // Post-processing configuration.
        configurePostProcessing(view: fv)

        // Cinematic lighting: a single sun, plus a fallback fill only when
        // there's no IBL to provide ambient light.
        setupDefaultLighting(engine: eng, scene: scn, hasIBL: hasIBL)

        // Apply any RenderConfig we already have — this builds color grading,
        // sun, and camera exposure together so they stay physically consistent.
        // (callers use update(config:) afterwards for graph-driven changes.)
        applyConfigIfNeeded(kCinematicDefaultConfig, engine: eng, view: fv)

        // Seed the device-adaptive quality tier (shadow fidelity, MSAA, TAA,
        // dynamic resolution, HDR precision) before the first real frame,
        // rather than leaving configurePostProcessing's hardcoded defaults in
        // place until the render loop's first tier check fires.
        appliedQualityTier = qualityController.currentTier
        applyQualityTier(qualityController.currentTier, view: fv)

        updateCamera()
    }

    /// Try to load the bundled studio-sky `.ktx` IBL/skybox pair from
    /// `Resources/IBL/` in the app bundle (generated via Filament's `cmgen`
    /// from a synthetic soft-key studio environment). Returns true only if
    /// both the reflections/irradiance probe and the skybox background
    /// loaded, so callers can fall back to a direct fill light otherwise.
    @discardableResult
    private func loadIBLIfAvailable(engine: OpaquePointer, scene: OpaquePointer) -> Bool {
        let bundle = Bundle.main
        func find(_ names: [String]) -> URL? {
            for name in names {
                if let url = bundle.url(forResource: name, withExtension: "ktx", subdirectory: "IBL") {
                    return url
                }
                if let url = bundle.url(forResource: name, withExtension: "ktx") {
                    return url
                }
            }
            return nil
        }

        // "_ibl" carries the prefiltered reflections cubemap (Filament also
        // derives diffuse irradiance from its roughest mip automatically).
        let iblURL = find(["default_ibl", "default_irradiance"])
        let skyboxURL = find(["default_skybox", "default_skybox_ibl"])

        var loadedIBL = false
        var loadedSky = false

        // Intensity kept modest relative to the 80,000 lux sun (roughly a
        // 1:10 fill ratio): the IBL is fully omnidirectional, so unlike real
        // outdoor skylight — which comes mostly from above and leaves a
        // visible dark/shadow side on an object — it wraps around and lights
        // every surface, including the sun-facing object's shadow side,
        // simultaneously. At the previous 30,000 lux that ambient fill was
        // strong enough to erase the light/dark falloff that reads as
        // "solid" on curved or non-metallic surfaces, leaving everything —
        // plastic worst of all, since it has no specular sheen to add
        // contrast back in — looking like a flat, evenly-glowing, washed-out
        // shell instead of an opaque lit object.
        if let url = iblURL,
           let ibl = filament_createIndirectLightFromKTX(engine, url.path, 8_000.0) {
            filament_setIndirectLight(scene, ibl)
            iblTexture = ibl
            loadedIBL = true
        }

        if let url = skyboxURL,
           let sky = filament_createSkyboxFromKTX(engine, url.path) {
            filament_setSkybox(scene, sky)
            skyboxTexture = sky
            loadedSky = true
        }

        if !loadedIBL || !loadedSky {
            print("FilamentRenderView: IBL assets missing (ibl=\(loadedIBL), skybox=\(loadedSky)). Falling back to a direct fill light.")
        }
        return loadedIBL && loadedSky
    }

    /// Configure bloom, SSAO, TAA, FXAA, dithering, shadow type.
    private func configurePostProcessing(view: OpaquePointer) {
        filament_viewSetBloomOptions(view, FilamentBloomOptions(
            enabled: true,
            strength: 0.04,
            threshold: 0.9,
            anamorphism: 0.0,
            levels: 6,
            blendMode: 0.0  // additive
        ))
        filament_viewSetAmbientOcclusionOptions(view, FilamentAmbientOcclusionOptions(
            enabled: true,
            radius: 0.5,
            power: 1.0,
            bias: 0.001,
            intensity: 0.7,
            quality: 2,  // HIGH — overwritten by the graphics-quality controller once it ticks
            bentNormals: true
        ))
        filament_viewSetDithering(view, 1)         // TEMPORAL
        filament_viewSetAntiAliasing(view, 1)       // FXAA
        filament_viewSetTemporalAntiAliasingOptions(view, FilamentTemporalAntiAliasingOptions(
            enabled: true,
            filterWidth: 1.0,
            historyWeight: 0.95,
            upscaling: false,
            varianceFilter: false
        ))
        filament_viewSetShadowType(view, 1)         // VSM (soft photographic shadows)
        filament_viewSetShadowingEnabled(view, true)
    }

    /// Build a ColorGrading pipeline from a RenderConfig. Called from
    /// applyConfig whenever the grading-relevant fields change; the previous
    /// pipeline is destroyed first since Filament ColorGrading objects are
    /// immutable once built.
    private func rebuildColorGrading(from config: RenderConfig, engine: OpaquePointer, view: OpaquePointer) {
        // RenderConfig.contrast/saturation are documented (and set by the
        // Scene Lighting node) as bipolar [-1, 1] with 0 = neutral. Filament's
        // ColorGrading builder instead expects [0.0, 2.0] with 1.0 = neutral
        // — passing our 0.0 straight through told it "zero saturation, near-
        // zero contrast," i.e. force everything to flat grey. Remap here.
        let filamentContrast = max(0.0, min(2.0, 1.0 + config.contrast))
        let filamentSaturation = max(0.0, min(2.0, 1.0 + config.saturation))
        guard let cg = filament_createColorGrading(
            engine,
            Float(config.exposure),             // artistic EV trim (camera exposure is physical, see applyConfig)
            Float(config.whiteBalanceKelvin),
            Float(filamentContrast),
            Float(filamentSaturation),
            Int32(config.toneMapper.rawValue),
            1.0,       // shadow gamma
            1.0,       // midPoint
            1.0        // highlight gamma
        ) else { return }
        if let old = colorGrading {
            filament_destroyColorGrading(engine, old)
        }
        filament_viewSetColorGrading(view, cg)
        colorGrading = cg
    }

    /// Single physically-plausible sun; ambient/fill normally comes entirely
    /// from IBL. Only add a soft direct fallback fill if IBL assets failed to
    /// load, so the shadow side of geometry doesn't go pure black.
    ///
    /// That fallback fill must be a genuinely direction-less ambient term
    /// (a flat IndirectLight), not another directional light: two
    /// directional lights each still cut off sharply at their own n·L == 0
    /// terminator, so the sphere would just be sliced into a warm
    /// sun-facing half and a cool "ambient"-facing half with a hard seam
    /// between them instead of one soft falloff on the shadow side.
    private func setupDefaultLighting(engine: OpaquePointer, scene: OpaquePointer, hasIBL: Bool) {
        sunLight = filament_createDirectionalLight(
            engine, scene,
            -0.55, -0.72, 0.41,        // upper-right-front
            1.0, 0.95, 0.88,           // warm white
            80_000.0,                   // intense (matches sunny-day EV)
            true                        // casts shadows
        )
        guard !hasIBL else { return }
        if let flatAmbient = filament_createFlatIndirectLight(engine, 0.45, 0.50, 0.62, 15_000.0) {
            filament_setIndirectLight(scene, flatAmbient)
            iblTexture = flatAmbient
        }
    }

    /// Apply a RenderConfig to the view. No-op if config is identical to the
    /// last one applied. Phase D wires graph-driven RenderConfig into this.
    private func applyConfigIfNeeded(_ config: RenderConfig,
                                     engine: OpaquePointer,
                                     view: OpaquePointer) {
        if config == lastAppliedConfig { return }
        applyConfig(config, engine: engine, view: view)
    }

    func applyConfig(_ config: RenderConfig,
                     engine: OpaquePointer,
                     view: OpaquePointer) {
        // Bloom / SSAO on-off and quality level are gated by the current
        // graphics-quality tier — device performance, not the graph, decides
        // how much of the post-processing budget these get to spend. Their
        // artistic parameters (strength, radius, power, ...) still come
        // straight from the graph-authored RenderConfig.
        let tier = qualityController.currentTier
        let tierAOQuality: Int32 = {
            switch tier {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            case .ultra: return 3
            }
        }()
        // Bloom
        filament_viewSetBloomOptions(view, FilamentBloomOptions(
            enabled: config.bloom.strength > 0.0 && tier > .low,
            strength: Float(config.bloom.strength),
            threshold: Float(config.bloom.threshold),
            anamorphism: Float(config.bloom.anamorphism),
            levels: Int32(tier == .ultra ? max(config.bloom.levels, 8) : config.bloom.levels),
            blendMode: Float(config.bloom.blendMode.rawValue)
        ))
        // SSAO
        filament_viewSetAmbientOcclusionOptions(view, FilamentAmbientOcclusionOptions(
            enabled: config.ssao.intensity > 0.0 && tier > .low,
            radius: Float(config.ssao.radius),
            power: Float(config.ssao.power),
            bias: Float(config.ssao.bias),
            intensity: Float(config.ssao.intensity),
            quality: tierAOQuality,
            bentNormals: tier >= .high
        ))
        // Fog
        if let fog = config.fog {
            filament_viewSetFogOptions(view, FilamentFogOptions(
                enabled: true,
                distance: Float(fog.distance),
                height: Float(fog.height),
                heightFalloff: Float(fog.heightFalloff),
                density: Float(fog.density),
                inScatteringStart: Float(fog.inScatteringStart),
                inScatteringEnd: Float(fog.inScatteringStart + fog.density * 50.0),
                fogColorFromIbl: fog.colorFromIBL,
                r: Float(fog.r), g: Float(fog.g), b: Float(fog.b)
            ))
        }
        // Sun direction + intensity
        if let sun = sunLight {
            filament_lightUpdateDirectional(
                sun,
                Float(config.sunDirection.x),
                Float(config.sunDirection.z),
                Float(-config.sunDirection.y),
                Float(config.sunColor.r),
                Float(config.sunColor.g),
                Float(config.sunColor.b),
                Float(config.sunIntensity),
                true
            )
        }
        // Point lights (Point Light nodes) — no in-place update entry point
        // exists in the bridge for POINT-type lights (only DIRECTIONAL), so
        // simply rebuild the set whenever the config changes. This method is
        // already gated behind `applyConfigIfNeeded`'s full-config equality
        // check, so it doesn't run on frames where nothing changed.
        if let scn = scene {
            for entity in pointLightEntities {
                filament_removeEntity(scn, entity)
            }
            pointLightEntities = config.pointLights.compactMap { light in
                filament_createPointLight(
                    engine, scn,
                    Float(light.position.x), Float(light.position.z), Float(-light.position.y),
                    Float(light.color.r), Float(light.color.g), Float(light.color.b),
                    Float(light.intensity)
                )
            }
        }
        // Camera exposure (EV100) — physical baseline that tracks sun
        // intensity (doubling the sun raises EV100 by one stop, keeping the
        // image correctly exposed regardless of how bright the graph's Sun
        // Lux input is set). The RenderConfig's `exposure` field is a
        // separate artistic trim applied via ColorGrading below, not here —
        // combining both here would double-count it.
        if let cam = camera {
            let ev100 = 15.0 + log2(max(config.sunIntensity, 1.0) / 80_000.0)
            filament_cameraSetExposureDirect(cam, Float(ev100))
        }
        // Color grading (tone mapper / contrast / saturation / white balance /
        // artistic exposure trim) — rebuilt whenever the config changes since
        // Filament's ColorGrading is immutable once built.
        rebuildColorGrading(from: config, engine: engine, view: view)

        lastAppliedConfig = config
    }

    private func teardownFilament() {
        guard let eng = engine else { return }

        // Filament requires resources to be destroyed in a specific order
        // before the engine itself. The engine MUST be the last thing destroyed.

        // 1. Destroy swap chain (no rendering without it)
        if let sw = swapChain {
            filament_destroySwapChain(eng, sw)
            swapChain = nil
        }

        // 2. Destroy renderer (depends on swap chain)
        if let rend = renderer {
            filament_destroyRenderer(eng, rend)
            renderer = nil
        }

        // 3. Detach IBL from scene, then destroy it
        if let scn = scene {
            filament_setIndirectLight(scn, nil)
        }
        if let ibl = iblTexture {
            filament_destroyIndirectLight(eng, ibl)
            iblTexture = nil
        }

        // 4. Detach skybox from scene, then destroy it
        if let scn = scene {
            filament_setSkybox(scn, nil)
        }
        if let sky = skyboxTexture {
            filament_destroySkybox(eng, sky)
            skyboxTexture = nil
        }

        // 5. Destroy color grading
        if let cg = colorGrading {
            filament_destroyColorGrading(eng, cg)
            colorGrading = nil
        }

        // 6. Remove all geometry entities from the scene.
        //    filament_removeEntity also destroys VBs, IBs, material instances,
        //    and the FilamentEntity wrapper itself.
        if let scn = scene {
            for entity in entities {
                filament_removeEntity(scn, entity)
            }
            entities.removeAll()

            for (_, entity) in entitiesByID {
                filament_removeEntity(scn, entity)
            }
            entitiesByID.removeAll()
            shapesByID.removeAll()

            // Remove light entities from the scene
            if let sun = sunLight {
                filament_removeEntity(scn, sun)
                sunLight = nil
            }
            for entity in pointLightEntities {
                filament_removeEntity(scn, entity)
            }
            pointLightEntities.removeAll()
        }

        // 7. Destroy view (cleans up texture cache disposer and other internal state)
        if let fv = filamentView {
            filament_destroyView(eng, fv)
            filamentView = nil
        }

        // 8. Destroy scene
        if let scn = scene {
            filament_destroyScene(eng, scn)
            scene = nil
        }

        // 9. Camera components are owned by entities managed through
        //    the EntityManager; they are cleaned up when the engine is destroyed.
        camera = nil

        // 10. Destroy the shared material instance cache. Entities holding these
        //     were already removed above without destroying the (shared)
        //     instance — this is the one place that actually frees them.
        for (_, instance) in materialInstanceCache {
            filament_engineDestroyMaterialInstance(eng, instance)
        }
        materialInstanceCache.removeAll()

        // 11. Destroy the engine (handles remaining internal cleanup)
        filament_destroyEngine(eng)
        engine = nil

        // Clear remaining state
        lastAppliedConfig = nil
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        guard !renderTimerActive else { return }
        renderTimerActive = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.renderFrame()
        }
        timer.resume()
        renderTimer = timer
    }

    private func stopRenderLoop() {
        guard renderTimerActive else { return }
        renderTimer?.cancel()
        renderTimer = nil
        renderTimerActive = false
    }

    private func renderFrame() {
        guard let rend = renderer,
              let fv = filamentView,
              let sw = swapChain else { return }

        let size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        cachedWidth = max(1, Int32(size.width * scale))
        cachedHeight = max(1, Int32(size.height * scale))
        cachedScale = scale

        // The Metal drawable's pixel size is decoupled from the view's bounds —
        // AppKit doesn't keep it in sync automatically. It's only set once at
        // setup time (often before SwiftUI has laid the view out to its final
        // size), so without updating it here every frame, the viewport below
        // grows/shrinks with the view while the actual backing texture stays
        // frozen at that first, usually-wrong size — rendering a clipped image
        // that no resize, zoom, or orbit can fix.
        let drawableSize = CGSize(width: CGFloat(cachedWidth), height: CGFloat(cachedHeight))
        if metalLayer?.drawableSize != drawableSize {
            metalLayer?.drawableSize = drawableSize
        }

        filament_viewSetViewport(fv, 0, 0, cachedWidth, cachedHeight)

        let frameStart = CFAbsoluteTimeGetCurrent()
        if filament_beginFrame(rend, sw) {
            filament_render(rend, fv)
            filament_endFrame(rend)
        }
        // Wall-clock duration of the encode+present call is a reliable proxy
        // for whether this Mac is keeping up: when the GPU/CPU can't keep
        // pace, this call blocks longer (waiting on a drawable or on
        // Filament's own backpressure), so a rising duration signals load
        // without needing a platform-specific GPU timer.
        qualityController.recordFrame(duration: CFAbsoluteTimeGetCurrent() - frameStart)
        if qualityController.currentTier != appliedQualityTier {
            appliedQualityTier = qualityController.currentTier
            applyQualityTier(qualityController.currentTier, view: fv)
        }
    }

    /// Apply a `GraphicsQualityTier`'s bundle of screen-space/post-processing
    /// settings: shadow fidelity, hardware MSAA, TAA, dynamic resolution, and
    /// HDR color-buffer precision. These are pure device-performance knobs
    /// (not graph-authored), unlike bloom/SSAO's artistic parameters (radius,
    /// strength, ...) which come from RenderConfig — but SSAO/bloom's
    /// on/off and quality level are ALSO tier-gated (see `applyConfig`), so
    /// re-running the last config here picks that up too.
    private func applyQualityTier(_ tier: GraphicsQualityTier, view: OpaquePointer) {
        switch tier {
        case .low:
            filament_viewSetShadowType(view, 0)  // PCF — cheapest shadow filter
            filament_viewSetAntiAliasing(view, 1)  // FXAA only
            filament_viewSetTemporalAntiAliasingOptions(view, FilamentTemporalAntiAliasingOptions(
                enabled: false, filterWidth: 1.0, historyWeight: 0.9, upscaling: false, varianceFilter: false))
            filament_viewSetMultiSampleAntiAliasingOptions(view, FilamentMultiSampleAntiAliasingOptions(
                enabled: false, sampleCount: 1, customResolve: false))
            filament_viewSetDynamicResolutionOptions(view, FilamentDynamicResolutionOptions(
                enabled: true, homogeneousScaling: true,
                minScaleX: 0.5, minScaleY: 0.5, maxScaleX: 1.0, maxScaleY: 1.0,
                sharpness: 0.9, quality: 1))
            filament_viewSetHdrColorBufferQuality(view, 0)
        case .medium:
            filament_viewSetShadowType(view, 0)  // PCF
            filament_viewSetAntiAliasing(view, 1)  // FXAA
            filament_viewSetTemporalAntiAliasingOptions(view, FilamentTemporalAntiAliasingOptions(
                enabled: false, filterWidth: 1.0, historyWeight: 0.9, upscaling: false, varianceFilter: false))
            filament_viewSetMultiSampleAntiAliasingOptions(view, FilamentMultiSampleAntiAliasingOptions(
                enabled: true, sampleCount: 2, customResolve: false))
            filament_viewSetDynamicResolutionOptions(view, FilamentDynamicResolutionOptions(
                enabled: true, homogeneousScaling: true,
                minScaleX: 0.75, minScaleY: 0.75, maxScaleX: 1.0, maxScaleY: 1.0,
                sharpness: 0.9, quality: 1))
            filament_viewSetHdrColorBufferQuality(view, 0)
        case .high:
            filament_viewSetShadowType(view, 1)  // VSM — soft photographic shadows
            filament_viewSetAntiAliasing(view, 1)  // FXAA
            filament_viewSetTemporalAntiAliasingOptions(view, FilamentTemporalAntiAliasingOptions(
                enabled: true, filterWidth: 1.0, historyWeight: 0.95, upscaling: false, varianceFilter: false))
            filament_viewSetMultiSampleAntiAliasingOptions(view, FilamentMultiSampleAntiAliasingOptions(
                enabled: true, sampleCount: 4, customResolve: false))
            filament_viewSetDynamicResolutionOptions(view, FilamentDynamicResolutionOptions(
                enabled: false, homogeneousScaling: true,
                minScaleX: 1.0, minScaleY: 1.0, maxScaleX: 1.0, maxScaleY: 1.0,
                sharpness: 0.9, quality: 0))
            filament_viewSetHdrColorBufferQuality(view, 1)
        case .ultra:
            filament_viewSetShadowType(view, 1)  // VSM
            filament_viewSetAntiAliasing(view, 1)  // FXAA
            filament_viewSetTemporalAntiAliasingOptions(view, FilamentTemporalAntiAliasingOptions(
                enabled: true, filterWidth: 1.0, historyWeight: 0.97, upscaling: false, varianceFilter: true))
            filament_viewSetMultiSampleAntiAliasingOptions(view, FilamentMultiSampleAntiAliasingOptions(
                enabled: true, sampleCount: 4, customResolve: true))
            filament_viewSetDynamicResolutionOptions(view, FilamentDynamicResolutionOptions(
                enabled: false, homogeneousScaling: true,
                minScaleX: 1.0, minScaleY: 1.0, maxScaleX: 1.0, maxScaleY: 1.0,
                sharpness: 0.9, quality: 0))
            filament_viewSetHdrColorBufferQuality(view, 1)
        }
        filament_viewSetShadowingEnabled(view, true)

        // Bloom/SSAO on/off + quality are also tier-gated (see applyConfig) —
        // re-apply the last graph-authored config so they pick up the tier
        // change too, without re-deriving sun/camera/color-grading state.
        if let eng = engine, let config = lastAppliedConfig {
            applyConfig(config, engine: eng, view: view)
        }
    }

    // MARK: - Mouse / Trackpad Input

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        setupTrackingArea()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastDragPoint.x)
        let dy = Float(point.y - lastDragPoint.y)

        switch interactionMode {
        case .object:
            // Object mode changes renderable transforms only. Lighting and the
            // camera deliberately remain in world space.
            objectYaw -= dx * 0.01
            objectPitch += dy * 0.01
            applyObjectTransform()

        case .viewport:
            // Viewport mode changes the camera only. Do not touch any scene
            // entity, including geometry and light sources.
            cameraTheta -= dx * 0.01
            cameraPhi += dy * 0.01
            cameraPhi = max(-1.5, min(1.5, cameraPhi))
            updateCamera()
        }

        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        cameraRadius *= (1.0 - dy * 0.001)
        cameraRadius = clampCameraRadius(cameraRadius)
        updateCamera()
    }

    override func magnify(with event: NSEvent) {
        cameraRadius *= (1.0 - Float(event.magnification))
        cameraRadius = clampCameraRadius(cameraRadius)
        updateCamera()
    }

    /// Zoom bounds scaled to the scene, not fixed constants — lets the user
    /// zoom well past what autoFrame picked in either direction while still
    /// preventing the camera from crossing through the target or drifting
    /// to a meaningless distance.
    private func clampCameraRadius(_ radius: Float) -> Float {
        let minRadius = max(sceneDiag * 0.01, 0.001)
        let maxRadius = max(sceneDiag * 50.0, 1.0)
        return max(minRadius, min(maxRadius, radius))
    }

    private func updateCamera() {
        guard let cam = camera else { return }
        let (tx, ty, tz) = cameraTarget

        filament_cameraOrbit(cam, cameraTheta, cameraPhi, cameraRadius, tx, ty, tz)

        let size = bounds.size
        let aspect = size.width > 0 ? Float(size.width / size.height) : 1.33
        // Near/far must scale with the scene, not be fixed constants: this
        // used to be a flat (0.1, 1000) regardless of scale. Grasshopper-style
        // parametric geometry can be any size, and the zoom range (see
        // clampCameraRadius) now legitimately goes well past 1000 units for
        // large scenes — the auto-framed distance alone (diag * 1.8) already
        // exceeded 1000 for a large-enough scene. Once the camera is farther
        // from the target than the far plane, the actual objects sit beyond
        // it and get culled entirely, while the (much wider) ground plane —
        // extending toward the camera — stays partially visible, so the
        // scene looked like it was rendering only a bare floor with no
        // objects, no matter how you orbited.
        //
        // near must track the *current* camera distance, not just the
        // scene's overall size — a near plane sized off sceneDiag alone
        // stops shrinking once you zoom in close (cameraRadius can go down
        // to sceneDiag * 0.01, only 10x above a fixed sceneDiag-based near),
        // so nearby geometry crosses the near plane and gets clipped with
        // the classic jagged/shattered look. Keep it a small fraction of
        // however far away the camera currently is instead.
        let near = max(cameraRadius * 0.005, 0.0001)
        let far = max(cameraRadius * 4.0, sceneDiag * 2.0) + near
        filament_cameraSetPerspective(cam, 45.0, aspect, near, far)
    }

    /// Rotate the geometry as a group around the auto-framed scene center.
    /// The transform is applied to mesh entities only, so the sun, IBL and
    /// camera remain in the same world-space positions.
    private func applyObjectTransform() {
        guard !entitiesByID.isEmpty else { return }
        let (cx, cy, cz) = cameraTarget
        let sy = sin(objectYaw), cyaw = cos(objectYaw)
        let sp = sin(objectPitch), cp = cos(objectPitch)

        // Column-major T(center) * Ry(yaw) * Rx(pitch) * T(-center).
        let rotation: [Float] = [
            cyaw,          0,       -sy,        0,
            sy * sp,       cp,       cyaw * sp, 0,
            sy * cp,      -sp,       cyaw * cp, 0,
            0,             0,         0,         1
        ]
        var matrix = rotation
        matrix[12] = cx - (rotation[0] * cx + rotation[4] * cy + rotation[8]  * cz)
        matrix[13] = cy - (rotation[1] * cx + rotation[5] * cy + rotation[9]  * cz)
        matrix[14] = cz - (rotation[2] * cx + rotation[6] * cy + rotation[10] * cz)

        for entity in entitiesByID.values {
            matrix.withUnsafeBufferPointer { buffer in
                filament_entitySetTransform(entity, buffer.baseAddress)
            }
        }
    }

    // MARK: - Material Application

    /// Get or create a cached material instance, keyed by a quantized
    /// `RenderKey` rather than exact `Material3D` equality. Materials that are
    /// mathematically connected in the graph (e.g. two Output nodes driven by
    /// the same upstream parameters through different arithmetic) can differ
    /// by a float epsilon; the quantized key still collapses them onto one
    /// shared instance so they render as a single connected material.
    private func materialInstance(for material: Material3D) -> OpaquePointer? {
        let key = material.renderKey
        if let existing = materialInstanceCache[key] { return existing }
        guard let engine = engine else { return nil }

        switch material.resolvedShadingFamily {
        case .metallicRoughness:
            guard let instance = filament_createDefaultMaterialInstance(engine) else { return nil }
            applyMaterialParams(instance: instance, material: material)
            materialInstanceCache[key] = instance
            return instance
        case .subsurface:
            guard let instance = filament_createSubsurfaceMaterialInstance(engine) else { return nil }
            applySubsurfaceMaterialParams(instance: instance, material: material)
            materialInstanceCache[key] = instance
            return instance
        }
    }

    /// Push Material3D parameters onto a `studio_pbr.mat` (metallic-roughness
    /// family) instance. Beyond the flat PBR factors, this also sends the
    /// procedural micro-detail knobs (bump/roughness-variation/scale/pattern)
    /// that studio_pbr.mat uses to turn a flat color into a surface with
    /// real, imperfect character, and the sheen layer (black = no sheen).
    private func applyMaterialParams(instance: OpaquePointer, material: Material3D) {
        filament_materialSetFloat4(instance, "baseColorFactor",
                                    Float(material.r), Float(material.g), Float(material.b), 1.0)
        filament_materialSetFloat(instance, "metallicFactor", Float(material.metalness))
        filament_materialSetFloat(instance, "roughnessFactor", Float(material.roughness))
        filament_materialSetFloat(instance, "reflectance", Float(material.specular))
        filament_materialSetFloat(instance, "clearCoatFactor", Float(material.clearcoat))
        filament_materialSetFloat(instance, "clearCoatRoughness", 0.0)
        filament_materialSetFloat(instance, "anisotropy", Float(material.anisotropy))
        filament_materialSetFloat3(instance, "sheenColorFactor",
                                    Float(material.sheenR), Float(material.sheenG), Float(material.sheenB))
        filament_materialSetFloat(instance, "sheenRoughnessFactor", Float(material.sheenRoughness))
        filament_materialSetFloat(instance, "normalDetail", Float(material.normal))
        filament_materialSetFloat(instance, "roughnessVariation", Float(material.roughnessVariation))
        filament_materialSetFloat(instance, "textureScale", Float(material.textureScale))
        filament_materialSetFloat(instance, "roughnessPattern", Float(material.patternIndex))
    }

    /// Push Material3D parameters onto a `studio_subsurface.mat` instance.
    /// Different uniform set from the metallic-roughness path above — no
    /// clear coat/anisotropy/sheen (they don't exist on the `subsurface`
    /// shading model), plus the translucency-specific subsurfacePower/
    /// subsurfaceColor/thickness triple.
    private func applySubsurfaceMaterialParams(instance: OpaquePointer, material: Material3D) {
        filament_materialSetFloat4(instance, "baseColorFactor",
                                    Float(material.r), Float(material.g), Float(material.b), 1.0)
        filament_materialSetFloat(instance, "metallicFactor", Float(material.metalness))
        filament_materialSetFloat(instance, "roughnessFactor", Float(material.roughness))
        filament_materialSetFloat(instance, "reflectance", Float(material.specular))
        filament_materialSetFloat(instance, "subsurfacePower", Float(material.subsurfacePower))
        filament_materialSetFloat3(instance, "subsurfaceColorFactor",
                                    Float(material.subsurfaceR), Float(material.subsurfaceG), Float(material.subsurfaceB))
        filament_materialSetFloat(instance, "thicknessFactor", Float(material.thickness))
        filament_materialSetFloat(instance, "normalDetail", Float(material.normal))
        filament_materialSetFloat(instance, "roughnessVariation", Float(material.roughnessVariation))
        filament_materialSetFloat(instance, "textureScale", Float(material.textureScale))
        filament_materialSetFloat(instance, "roughnessPattern", Float(material.patternIndex))
    }

    /// Pull the painted material off a shape if any. Default to a neutral grey.
    private func materialOf(_ shape: GeometricShape) -> Material3D {
        shape.material()
    }

    /// Strip painted/styled wrappers to get the underlying geometry shape.
    private func unwrapShape(_ shape: GeometricShape) -> GeometricShape {
        shape.unwrapForRendering()
    }

    // MARK: - Geometry Population

    /// Phase B: diff the entity map against the tracked shape stream.
    /// - Matches by UUID; reuses entities when shape == previous shape.
    /// - Rebuilds when shape kind/params change.
    /// - Destroys entities no longer present in the stream.
    /// - Also applies any RenderConfig changes (Phase D wiring).
    func update(trackedShapes: [TrackedShape], renderConfig: RenderConfig,
                interactionMode: RealisticInteractionMode) {
        let modeChanged = self.interactionMode != interactionMode
        self.interactionMode = interactionMode
        // A picker change can arrive while AppKit still considers the mouse
        // pressed. The next drag must start with a fresh delta so it cannot
        // apply the previous mode's motion to the newly selected target.
        if modeChanged {
            isDragging = false
        }
        guard filamentSetupDone, let eng = engine, let scn = scene else {
            pendingTrackedShapes = trackedShapes
            pendingRenderConfig = renderConfig
            return
        }

        // Apply RenderConfig if it changed (Phase D).
        applyConfigIfNeeded(renderConfig, engine: eng, view: filamentView!)

        // First-frame setup: build the entity map fresh.
        if entitiesByID.isEmpty && shapesByID.isEmpty {
            for tracked in trackedShapes {
                let material = tracked.shape.material()
                let geometry = tracked.shape.unwrapForRendering()
                guard let mi = materialInstance(for: material) else {
                    continue
                }
                if let entity = makeEntity(engine: eng, scene: scn, shape: geometry, material: mi) {
                    entitiesByID[tracked.id] = entity
                    shapesByID[tracked.id] = tracked.shape
                }
            }
            // Auto-frame on first populate.
            autoFrame(shapes: trackedShapes.map(\.shape))
            applyObjectTransform()
            updateCamera()
            return
        }

        // Compute new state from the diff.
        let previousShapeCount = shapesByID.count
        var newEntitiesByID: [UUID: OpaquePointer] = [:]
        var newShapesByID: [UUID: GeometricShape] = [:]
        let inputIDs = Set(trackedShapes.map(\.id))

        for tracked in trackedShapes {
            let prevShape = shapesByID[tracked.id]
            let prevEntity = entitiesByID[tracked.id]

            if let prevEntity = prevEntity, let prevShape = prevShape, prevShape == tracked.shape {
                // No change: reuse.
                newEntitiesByID[tracked.id] = prevEntity
                newShapesByID[tracked.id] = tracked.shape
                continue
            }

            // Shape changed (or is new). Destroy the old entity if any, build a new one.
            if let prevEntity = prevEntity {
                filament_removeEntity(scn, prevEntity)
            }

            let material = tracked.shape.material()
            let geometry = tracked.shape.unwrapForRendering()
            guard let mi = materialInstance(for: material) else {
                continue
            }
            if let entity = makeEntity(engine: eng, scene: scn, shape: geometry, material: mi) {
                newEntitiesByID[tracked.id] = entity
                newShapesByID[tracked.id] = tracked.shape
            }
        }

        // Destroy entities whose IDs no longer appear.
        for (id, entity) in entitiesByID where !inputIDs.contains(id) {
            filament_removeEntity(scn, entity)
        }

        entitiesByID = newEntitiesByID
        shapesByID = newShapesByID

        // Re-frame only when objects were actually added or removed — not on
        // every bounds/position tweak of existing geometry. Re-snapping the
        // camera on every minor update used to fight live camera control: a
        // continuously re-evaluating graph (or even just repeated redundant
        // SwiftUI update calls) could retrigger this while the user was mid
        // drag/scroll, yanking the camera back to a fresh auto-framed spot
        // every time — visible as the whole scene flickering/jumping. (This
        // previously compared against `shapesByID` *after* it had just been
        // reassigned above, so "previous" and "new" bounds were nearly always
        // identical anyway — the check was accidentally almost a no-op, and
        // whatever the real update frequency, this makes the behavior
        // intentional and correct instead of order-of-operations luck.)
        if newEntitiesByID.count != previousShapeCount {
            autoFrame(shapes: trackedShapes.map(\.shape))
            applyObjectTransform()
            updateCamera()
        } else if modeChanged || interactionMode == .object {
            applyObjectTransform()
        }
    }

    private func autoFrame(shapes: [GeometricShape]) {
        let bounds = computeBounds(shapes: shapes)
        let cx = Float(bounds.min.x + bounds.max.x) * 0.5
        let cy = Float(bounds.min.y + bounds.max.y) * 0.5
        let cz = Float(bounds.min.z + bounds.max.z) * 0.5
        let dx = Float(bounds.max.x - bounds.min.x)
        let dy = Float(bounds.max.y - bounds.min.y)
        let dz = Float(bounds.max.z - bounds.min.z)
        let diag = sqrt(dx * dx + dy * dy + dz * dz)
        sceneDiag = max(diag, 0.01)
        cameraTarget = (cx, cz, -cy)
        cameraRadius = max(diag * 1.8, 1.0)
    }

    /// Phase A fallback — full rebuild. Kept for diagnostic / debug paths.
    func populate(shapes: [GeometricShape]) {
        let tracked = shapes.enumerated().map { idx, shape in
            TrackedShape(id: UUID(), shape: shape)
        }
        update(trackedShapes: tracked, renderConfig: .cinematicDefault,
               interactionMode: interactionMode)
    }

    // MARK: - Shape → Entity Mapping

    private func makeEntity(engine: OpaquePointer,
                            scene: OpaquePointer,
                            shape: GeometricShape,
                            material: OpaquePointer?) -> OpaquePointer? {
        switch shape {
        case .point(let p):
            return filament_createSphere(engine, scene, material,
                Float(p.x), Float(p.z), Float(-p.y), 0.16, 32)

        case .sphere(let center, let radius):
            return filament_createSphere(engine, scene, material,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), 64)

        case .box(let minPt, let maxPt):
            return filament_createBox(engine, scene, material,
                Float(minPt.x), Float(minPt.z), Float(-maxPt.y),
                Float(maxPt.x), Float(maxPt.z), Float(-minPt.y))

        case .cylinder(let center, let radius, let height):
            return filament_createCylinder(engine, scene, material,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), Float(height), 64)

        case .cone(let center, let radius, let height):
            return filament_createCone(engine, scene, material,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), Float(height), 64)

        case .torus(let center, let majorR, let minorR):
            return filament_createTorus(engine, scene, material,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(majorR), Float(minorR), 96, 32)

        case .circle(let center, let radius):
            return filament_createDisc(engine, scene, material,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), 64)

        case .polygon(let points):
            var flat = [Float]()
            flat.reserveCapacity(points.count * 3)
            for pt in points {
                flat.append(Float(pt.x))
                flat.append(Float(pt.z))
                flat.append(Float(-pt.y))
            }
            return flat.withUnsafeBufferPointer { buf in
                filament_createPolygon(engine, scene, material,
                    buf.baseAddress, Int32(points.count), 0.04)
            }

        case .surfaceStrip(let curveA, let curveB):
            var flatA = [Float]()
            flatA.reserveCapacity(curveA.count * 3)
            for pt in curveA {
                flatA.append(Float(pt.x))
                flatA.append(Float(pt.z))
                flatA.append(Float(-pt.y))
            }
            var flatB = [Float]()
            flatB.reserveCapacity(curveB.count * 3)
            for pt in curveB {
                flatB.append(Float(pt.x))
                flatB.append(Float(pt.z))
                flatB.append(Float(-pt.y))
            }
            return flatA.withUnsafeBufferPointer { bufA in
                flatB.withUnsafeBufferPointer { bufB in
                    filament_createSurfaceStrip(engine, scene, material,
                        bufA.baseAddress, Int32(curveA.count),
                        bufB.baseAddress, Int32(curveB.count))
                }
            }

        case .mesh(let verts, let tris):
            guard !verts.isEmpty, !tris.isEmpty else { return nil }
            let normals = MeshKernel.vertexNormals((verts, tris))
            var flatPos = [Float](); flatPos.reserveCapacity(verts.count * 3)
            var flatNorm = [Float](); flatNorm.reserveCapacity(verts.count * 3)
            for (i, p) in verts.enumerated() {
                flatPos.append(Float(p.x)); flatPos.append(Float(p.z)); flatPos.append(Float(-p.y))
                let n = normals[i]
                flatNorm.append(Float(n.x)); flatNorm.append(Float(n.z)); flatNorm.append(Float(-n.y))
            }
            let flatIdx = tris.map { UInt32($0) }
            return flatPos.withUnsafeBufferPointer { posBuf in
                flatNorm.withUnsafeBufferPointer { normBuf in
                    flatIdx.withUnsafeBufferPointer { idxBuf in
                        filament_createMesh(engine, scene, material,
                            posBuf.baseAddress, normBuf.baseAddress, Int32(verts.count),
                            idxBuf.baseAddress, Int32(flatIdx.count))
                    }
                }
            }

        case .line(let start, let end):
            return filament_createLine(engine, scene, material,
                Float(start.x), Float(start.z), Float(-start.y),
                Float(end.x), Float(end.z), Float(-end.y),
                0.045)

        case .polyline(let points):
            guard points.count >= 2 else { return nil }
            for i in 0..<(points.count - 1) {
                let a = points[i]
                let b = points[i + 1]
                _ = filament_createLine(engine, scene, material,
                    Float(a.x), Float(a.z), Float(-a.y),
                    Float(b.x), Float(b.z), Float(-b.y),
                    0.045)
            }
            return nil  // Lines don't return a single entity handle.

        case .spline(let cps, let degree, let closed):
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed)
            return makeEntity(engine: engine, scene: scene, shape: .polyline(pts), material: material)

        case .label:
            return nil

        case .styled2D(let inner, _):
            return makeEntity(engine: engine, scene: scene, shape: inner, material: material)

        case .painted(let inner, _):
            // Defensive — `populate` already unwraps painted. Recurse anyway.
            return makeEntity(engine: engine, scene: scene, shape: inner, material: material)
        }
    }

    // MARK: - Bounds Computation

    private func computeBounds(shapes: [GeometricShape]) -> (min: Point3D, max: Point3D) {
        var minPt = Point3D(x: .infinity, y: .infinity, z: .infinity)
        var maxPt = Point3D(x: -.infinity, y: -.infinity, z: -.infinity)

        func expand(_ p: Point3D) {
            if p.x < minPt.x { minPt.x = p.x }
            if p.y < minPt.y { minPt.y = p.y }
            if p.z < minPt.z { minPt.z = p.z }
            if p.x > maxPt.x { maxPt.x = p.x }
            if p.y > maxPt.y { maxPt.y = p.y }
            if p.z > maxPt.z { maxPt.z = p.z }
        }

        func collect(_ shape: GeometricShape) {
            switch shape {
            case .point(let p):
                expand(p)
            case .sphere(let c, let r):
                expand(Point3D(x: c.x - r, y: c.y - r, z: c.z - r))
                expand(Point3D(x: c.x + r, y: c.y + r, z: c.z + r))
            case .box(let a, let b):
                expand(a); expand(b)
            case .cylinder(let c, let r, let h):
                let hh = h * 0.5
                expand(Point3D(x: c.x - r, y: c.y - hh, z: c.z - r))
                expand(Point3D(x: c.x + r, y: c.y + hh, z: c.z + r))
            case .cone(let c, let r, let h):
                let hh = h * 0.5
                expand(Point3D(x: c.x - r, y: c.y - hh, z: c.z - r))
                expand(Point3D(x: c.x + r, y: c.y + hh, z: c.z + r))
            case .torus(let c, let mr, let mn):
                let rr = mr + mn
                expand(Point3D(x: c.x - rr, y: c.y - mn, z: c.z - rr))
                expand(Point3D(x: c.x + rr, y: c.y + mn, z: c.z + rr))
            case .circle(let c, let r):
                expand(Point3D(x: c.x - r, y: c.y, z: c.z - r))
                expand(Point3D(x: c.x + r, y: c.y, z: c.z + r))
            case .polygon(let pts):
                for p in pts { expand(p) }
            case .surfaceStrip(let a, let b):
                for p in a { expand(p) }
                for p in b { expand(p) }
            case .line(let a, let b):
                expand(a); expand(b)
            case .polyline(let pts):
                for p in pts { expand(p) }
            case .mesh(let verts, _):
                for p in verts { expand(p) }
            case .spline(let cps, let degree, let closed):
                for p in CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed) { expand(p) }
            case .label(_, let p):
                expand(p)
            case .painted(let inner, _):
                collect(inner)
            case .styled2D(let inner, _):
                collect(inner)
            }
        }

        for shape in shapes { collect(shape) }

        if minPt.x == .infinity {
            return (Point3D(x: -5, y: -5, z: -5), Point3D(x: 5, y: 5, z: 5))
        }
        return (minPt, maxPt)
    }
}

// MARK: - SwiftUI Representable

/// SwiftUI wrapper that embeds the Filament-powered 3D preview.
/// Phase B takes tracked shapes for entity diffing; Phase D reads RenderConfig.
struct FilamentRenderView: NSViewRepresentable {
    let shapes: [TrackedShape]
    var renderConfig: RenderConfig = .cinematicDefault
    var interactionMode: RealisticInteractionMode = .viewport

    func makeNSView(context: Context) -> FilamentHostView {
        let hostView = FilamentHostView(frame: .zero)
        hostView.autoresizingMask = [.width, .height]
        return hostView
    }

    func updateNSView(_ nsView: FilamentHostView, context: Context) {
        nsView.update(trackedShapes: shapes, renderConfig: renderConfig,
                      interactionMode: interactionMode)
    }
}
