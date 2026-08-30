import MetalKit
import simd

/// Hosts the Metal ray-tracing path tracer inside an `MTKView`. Owns its own
/// `MTLDevice`/command queue (nothing in the app currently shares a device
/// between Swift and Filament's internal ObjC++ bridge — see
/// `FilamentRenderView.swift` — so this mode does the same independent thing).
///
/// Every `draw(in:)` call adds one more sample to a running-average
/// accumulation texture and resolves it (tonemapped) to the drawable. Any
/// change to geometry, materials, or lights resets accumulation from zero —
/// path-traced convergence is only meaningful against a static scene, which
/// is exactly what makes the image visibly refine over time instead of being
/// instant like the real-time Filament view. A camera move resets too, but
/// warm-starts from a reprojection of the outgoing image instead of zero
/// samples — see `reprojectKernel` in `PathTracerShaders.metal` — so
/// orbiting/panning/zooming stays comparatively clean rather than flashing
/// back to raw noise on every drag tick.
final class PathTracerHostView: MTKView, MTKViewDelegate {

    /// Sample budget where *converged* pixels (see the per-pixel Welford
    /// stats texture) stop tracing; still-noisy pixels keep going past this
    /// up to `hardCapSampleCount`. Renamed from the old fixed `targetSampleCount`
    /// now that sampling is adaptive rather than a single flat budget.
    static let softCapSampleCount = 1024
    static let hardCapSampleCount = 4096

    var onSampleCountChanged: ((Int, Int) -> Void)?

    /// Target relative standard error for a pixel to be considered converged
    /// (see `PTSceneUniforms.targetRelativeError`). Lower = more samples
    /// before a pixel stops, less noise. Settable from the UI (Phase 6).
    var noiseTarget: Float = 0.03
    /// If false, sampling stops flat at `softCapSampleCount` regardless of
    /// per-pixel convergence (the pre-adaptive-sampling behavior).
    var allowExtendedSampling: Bool = true

    private let commandQueue: MTLCommandQueue
    private let scene: PathTracerScene
    private var tracePipeline: MTLComputePipelineState?
    private var resolvePipeline: MTLComputePipelineState?
    private var clearStatsPipeline: MTLComputePipelineState?
    private var reprojectPipeline: MTLComputePipelineState?

    private var accumTexture: MTLTexture?
    private var statsTexture: MTLTexture?
    // Primary-hit world position for the current camera (see
    // `PathTracerShaders.metal`'s `reprojectKernel` doc comment), plus a
    // one-frame-lagged snapshot of both used as reprojection history the
    // moment a camera-only reset fires.
    private var positionTexture: MTLTexture?
    private var historyAccumTexture: MTLTexture?
    private var historyPositionTexture: MTLTexture?
    private var accumTextureSize: MTLSize = MTLSize(width: 0, height: 0, depth: 0)
    private var frameIndex: Int = 0
    private var sceneGenerationSeen: Int = -1
    private var hasAutoFramed = false
    private var statsNeedsClear = true

    // Camera basis that produced the content currently sitting in
    // `accumTexture`/`positionTexture` — snapshotted into the history
    // textures the next time a camera-only reset needs something to
    // reproject against. `nil` until the first frame ever completes.
    private var previousFrameCamera: PTCameraUniforms?
    // Set by a camera-only reset (drag/scroll/zoom); consumed by the next
    // `draw(in:)`, which either runs `reprojectKernel` (if history is
    // available) or falls back to the normal hard-clear path.
    private var pendingReprojection = false

    // Per-frame count of pixels the trace kernel actually traced (i.e. didn't
    // early-exit as already converged) — read back one frame late via
    // `addCompletedHandler`, used to decide whether to keep dispatching past
    // `softCapSampleCount` at all.
    private var activeSampleCounterBuffer: MTLBuffer?
    private var lastActiveSampleCount: Int = .max // optimistic until the first real readback

    // OIDN Metal denoiser — periodic GPU-side refinement pass over
    // `accumTexture`, see `OIDNDenoiser` for why it isn't run every frame.
    private let denoiser: OIDNDenoiser?
    var denoiseEnabled = true {
        didSet {
            if !denoiseEnabled { denoisedTexture = nil }
        }
    }
    private var denoisedTexture: MTLTexture?
    private var lastDenoiseTriggerFrame: Int = -1
    private var denoiseGeneration = 0
    // Tightened from 16: reprojection (see `pendingReprojection` above) now
    // hands frame 0 a head start after most camera moves, so a denoise pass
    // a few samples later already has decent per-pixel history to work with
    // instead of near-pure noise — worth refreshing the screen more often
    // during interaction rather than waiting out the old, coarser cadence.
    private static let denoiseSampleInterval = 4

    // Orbit camera — same drag-orbits/scroll-zooms convention as
    // `FilamentHostView`'s viewport interaction mode.
    private var cameraTheta: Float = 0.7
    private var cameraPhi: Float = 0.5
    private var cameraRadius: Float = 25.0
    private var cameraTarget = SIMD3<Float>(0, 0, 0)
    private var sceneDiag: Float = 10.0
    private var isDragging = false
    private var lastDragPoint: CGPoint = .zero

    private var latestRenderConfig: RenderConfig = .cinematicDefault

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("PathTracerHostView: Metal is not available on this device")
        }
        commandQueue = queue
        scene = PathTracerScene(device: device)
        denoiser = OIDNDenoiser(device: device)
        if denoiser == nil {
            print("PathTracerHostView: OIDN Metal denoiser unavailable on this device — running without denoising")
        }
        super.init(frame: .zero, device: device)

        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        delegate = self
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 30

        buildPipelines(device: device)
        activeSampleCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        setupTrackingArea()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildPipelines(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            print("PathTracerHostView: failed to load default Metal library")
            return
        }
        do {
            if let traceFn = library.makeFunction(name: "pathTraceKernel") {
                tracePipeline = try device.makeComputePipelineState(function: traceFn)
            }
            if let resolveFn = library.makeFunction(name: "resolveKernel") {
                resolvePipeline = try device.makeComputePipelineState(function: resolveFn)
            }
            if let clearFn = library.makeFunction(name: "clearStatsKernel") {
                clearStatsPipeline = try device.makeComputePipelineState(function: clearFn)
            }
            if let reprojectFn = library.makeFunction(name: "reprojectKernel") {
                reprojectPipeline = try device.makeComputePipelineState(function: reprojectFn)
            }
        } catch {
            print("PathTracerHostView: failed to build compute pipelines: \(error)")
        }
    }

    // MARK: - Public API

    func update(trackedShapes: [TrackedShape], renderConfig: RenderConfig) {
        latestRenderConfig = renderConfig
        let changed = scene.update(trackedShapes: trackedShapes, renderConfig: renderConfig, commandQueue: commandQueue)
        if changed {
            resetAccumulation()
            if !hasAutoFramed, scene.accelerationStructure != nil {
                autoFrame()
                hasAutoFramed = true
            }
        }
    }

    /// `reprojectable` should be true only for a reset that leaves the scene
    /// and geometry untouched (camera orbit/pan/zoom) — anything that
    /// changes what's actually in the accumulation buffer (a scene edit, a
    /// resize) must hard-reset instead, since there is nothing valid to
    /// reproject against.
    func resetAccumulation(reprojectable: Bool = false) {
        if reprojectable, frameIndex > 0, previousFrameCamera != nil {
            pendingReprojection = true
        } else {
            pendingReprojection = false
            previousFrameCamera = nil
        }
        frameIndex = 0
        lastDenoiseTriggerFrame = -1
        denoisedTexture = nil
        denoiseGeneration += 1
        statsNeedsClear = true
        lastActiveSampleCount = .max
    }

    private func autoFrame() {
        let (lo, hi) = scene.sceneBounds
        cameraTarget = (lo + hi) * 0.5
        let diag = length(hi - lo)
        sceneDiag = max(diag, 0.01)
        cameraRadius = max(diag * 1.8, 1.0)
    }

    // MARK: - Camera

    private func cameraBasis() -> (position: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        let cosT = cos(cameraTheta), sinT = sin(cameraTheta)
        let cosP = cos(cameraPhi), sinP = sin(cameraPhi)
        let offset = SIMD3<Float>(cosP * sinT, sinP, cosP * cosT) * cameraRadius
        let position = cameraTarget + offset
        let forward = normalize(cameraTarget - position)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = cross(right, forward)
        return (position, forward, right, up)
    }

    private func clampCameraRadius(_ radius: Float) -> Float {
        let minRadius = max(sceneDiag * 0.01, 0.001)
        let maxRadius = max(sceneDiag * 50.0, 1.0)
        return max(minRadius, min(maxRadius, radius))
    }

    // MARK: - Mouse / trackpad input

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
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
        cameraTheta -= dx * 0.01
        cameraPhi = max(-1.5, min(1.5, cameraPhi + dy * 0.01))
        lastDragPoint = point
        resetAccumulation(reprojectable: true)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        cameraRadius = clampCameraRadius(cameraRadius * (1.0 - dy * 0.001))
        resetAccumulation(reprojectable: true)
    }

    override func magnify(with event: NSEvent) {
        cameraRadius = clampCameraRadius(cameraRadius * (1.0 - Float(event.magnification)))
        resetAccumulation(reprojectable: true)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        accumTexture = nil
        statsTexture = nil
        resetAccumulation()
    }

    private func ensureAccumTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if let existing = accumTexture, accumTextureSize.width == width, accumTextureSize.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        accumTexture = texture
        accumTextureSize = MTLSize(width: width, height: height, depth: 1)
        frameIndex = 0
        // Force stats/position/history to match the new size too — and drop
        // any reprojection state, since none of it means anything against a
        // different resolution.
        statsTexture = nil
        positionTexture = nil
        historyAccumTexture = nil
        historyPositionTexture = nil
        previousFrameCamera = nil
        pendingReprojection = false
        return texture
    }

    private func ensureStatsTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if let existing = statsTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        statsTexture = texture
        statsNeedsClear = true
        return texture
    }

    private func ensurePositionTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if let existing = positionTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        positionTexture = texture
        return texture
    }

    /// Lazily allocates the two reprojection-history textures (same size as
    /// `accumTexture`/`positionTexture`, which by construction match by the
    /// time this is called — see `ensureAccumTexture`). Their contents only
    /// ever matter for the single frame right after a camera-only reset —
    /// see `reprojectKernel`'s doc comment — so there's no "needs clear"
    /// bookkeeping to mirror `ensureStatsTexture`'s: they're fully
    /// overwritten by a blit immediately before every use.
    private func ensureHistoryTextures(device: MTLDevice, width: Int, height: Int) -> (accum: MTLTexture, position: MTLTexture)? {
        if let a = historyAccumTexture, let p = historyPositionTexture { return (a, p) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let accum = device.makeTexture(descriptor: descriptor),
              let position = device.makeTexture(descriptor: descriptor) else { return nil }
        historyAccumTexture = accum
        historyPositionTexture = position
        return (accum, position)
    }

    /// EV100 -> photographic exposure multiplier, same formula
    /// `FilamentHostView.applyConfig` derives from `RenderConfig.sunIntensity`
    /// (`ev100 = 15 + log2(sunIntensity / 80_000)`) so both render modes land
    /// on comparable brightness for the same scene.
    private func exposureMultiplier() -> Float {
        let ev100 = 15.0 + log2(max(latestRenderConfig.sunIntensity, 1.0) / 80_000.0)
        return Float(1.0 / (1.2 * pow(2.0, ev100)))
    }

    func draw(in view: MTKView) {
        guard let device = device,
              let drawable = currentDrawable,
              let tracePipeline, let resolvePipeline,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)
        guard width > 0, height > 0,
              let accumTexture = ensureAccumTexture(device: device, width: width, height: height),
              let statsTexture = ensureStatsTexture(device: device, width: width, height: height),
              let positionTexture = ensurePositionTexture(device: device, width: width, height: height) else { return }

        // Resolved once, up front — including allocating the history
        // textures — so both the stats-clear gate below and the
        // reprojection dispatch further down agree on whether this frame is
        // actually going to reproject; a `willReproject == true` that later
        // failed to materialize would leave `statsTexture` un-cleared *and*
        // un-seeded, letting stale convergence flags from the pre-reset
        // accumulation wrongly gate this cycle's tracing. Consumed
        // unconditionally either way — there's nothing left to retry next
        // frame.
        let historyTextures = (pendingReprojection && previousFrameCamera != nil)
            ? ensureHistoryTextures(device: device, width: width, height: height) : nil
        let willReproject = pendingReprojection && previousFrameCamera != nil && reprojectPipeline != nil
            && scene.accelerationStructure != nil && historyTextures != nil
        pendingReprojection = false

        if statsNeedsClear, !willReproject, let clearStatsPipeline,
           let clearEncoder = commandBuffer.makeComputeCommandEncoder() {
            clearEncoder.setComputePipelineState(clearStatsPipeline)
            clearEncoder.setTexture(statsTexture, index: 0)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
            clearEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            clearEncoder.endEncoding()
            statsNeedsClear = false
        }

        // Soft cap: converged pixels stop here. Hard cap: absolute ceiling
        // regardless of convergence. Between the two, keep dispatching only
        // while last frame's readback says at least one pixel is still
        // actively tracing (or extended sampling is disabled, in which case
        // the soft cap behaves like the old flat budget).
        let keepDispatching = frameIndex < Self.hardCapSampleCount
            && (frameIndex < Self.softCapSampleCount || (allowExtendedSampling && lastActiveSampleCount > 0))

        if let accel = scene.accelerationStructure,
           let vertexBuffer = scene.vertexBuffer, let normalBuffer = scene.normalBuffer,
           let indexBuffer = scene.indexBuffer, let triMatBuffer = scene.triangleMaterialBuffer,
           let materialBuffer = scene.materialBuffer, let pointLightBuffer = scene.pointLightBuffer,
           let lightTreeBuffer = scene.lightTreeBuffer, let lightRefBuffer = scene.lightRefBuffer,
           let triToRecordBuffer = scene.trianglePrimIDToLightRecordBuffer,
           let recordToLeafBuffer = scene.lightRecordToLeafNodeBuffer,
           let activeSampleCounterBuffer,
           keepDispatching {

            let basis = cameraBasis()
            let aspect = Float(width) / Float(height)
            var cameraUniforms = PTCameraUniforms(
                position: basis.position, forward: basis.forward, right: basis.right, up: basis.up,
                tanHalfFov: Float(tan(45.0 * Double.pi / 180.0 * 0.5)),
                aspect: aspect,
                frameIndex: UInt32(frameIndex),
                width: UInt32(width), height: UInt32(height)
            )

            let renderConfig = latestRenderConfig
            let sunDirWorld = SIMD3<Float>(Float(renderConfig.sunDirection.x), Float(renderConfig.sunDirection.z), Float(-renderConfig.sunDirection.y))
            // RenderConfig.sunDirection is the direction the sun *travels*
            // (matches Filament's directional-light convention); shading
            // needs the direction *toward* the sun, so negate here.
            let volume = renderConfig.pathTracerVolume
            let globalVolume = PTMediumUniforms(
                sigmaS: volume.enabled ? SIMD3(Float(volume.colorR), Float(volume.colorG), Float(volume.colorB)) * Float(volume.density) : SIMD3(0, 0, 0),
                sigmaA: volume.enabled ? SIMD3(repeating: Float(volume.density) * 0.1) : SIMD3(0, 0, 0),
                g: Float(volume.anisotropy),
                heightFalloff: Float(volume.heightFalloff),
                enabled: volume.enabled ? 1 : 0
            )
            // Pre-exposure luminance above which a single NEE sample gets
            // clamped (see `PTSceneUniforms.fireflyClamp`'s doc comment).
            // Scaled by 1/exposure rather than a fixed constant so it tracks
            // the scene's own brightness controls: ~16x post-exposure "white"
            // is generously above anything a well-behaved direct-lighting
            // sample should read as, while still catching the rare
            // narrow-pdf/low-roughness spike.
            let fireflyClamp: Float = 16.0 / max(exposureMultiplier(), 1e-8)

            var sceneUniforms = PTSceneUniforms(
                sunDirection: -normalize(sunDirWorld),
                sunColor: SIMD3(Float(renderConfig.sunColor.r), Float(renderConfig.sunColor.g), Float(renderConfig.sunColor.b)) * Float(renderConfig.sunIntensity),
                sunAngularRadius: 0.045,
                skyZenith: SIMD3(0.32, 0.45, 0.65),
                skyHorizon: SIMD3(0.75, 0.78, 0.82),
                pointLightCount: UInt32(scene.pointLightCount),
                maxBounces: 6,
                globalVolume: globalVolume,
                lightTreeNodeCount: UInt32(scene.lightTreeNodeCount),
                targetRelativeError: noiseTarget,
                minSamplesBeforeCheck: 32,
                fireflyClamp: fireflyClamp
            )

            // Reprojection: right after a camera-only reset, warm-start this
            // frame's accum/stats from the *previous* camera's accumulated
            // image instead of starting every pixel from zero samples (see
            // `reprojectKernel`'s doc comment). Snapshot the outgoing
            // accum/position content into the history textures first — the
            // reproject kernel below will overwrite `accumTexture`/
            // `statsTexture` themselves, so it can't read history out of
            // those same textures without racing its own writes.
            if willReproject, var historyCamera = previousFrameCamera,
               let reprojectPipeline, let history = historyTextures,
               let historyBlit = commandBuffer.makeBlitCommandEncoder() {
                historyBlit.copy(from: accumTexture, sourceSlice: 0, sourceLevel: 0,
                                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: accumTextureSize,
                                  to: history.accum, destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                historyBlit.copy(from: positionTexture, sourceSlice: 0, sourceLevel: 0,
                                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: accumTextureSize,
                                  to: history.position, destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                historyBlit.endEncoding()

                if let reprojectEncoder = commandBuffer.makeComputeCommandEncoder() {
                    reprojectEncoder.setComputePipelineState(reprojectPipeline)
                    reprojectEncoder.setTexture(history.accum, index: 0)
                    reprojectEncoder.setTexture(history.position, index: 1)
                    reprojectEncoder.setTexture(accumTexture, index: 2)
                    reprojectEncoder.setTexture(statsTexture, index: 3)
                    reprojectEncoder.setBytes(&cameraUniforms, length: MemoryLayout<PTCameraUniforms>.stride, index: 0)
                    reprojectEncoder.setBytes(&historyCamera, length: MemoryLayout<PTCameraUniforms>.stride, index: 1)
                    reprojectEncoder.setAccelerationStructure(accel, bufferIndex: 2)
                    reprojectEncoder.useResource(vertexBuffer, usage: .read)
                    reprojectEncoder.useResource(indexBuffer, usage: .read)
                    let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
                    let threadgroups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
                    reprojectEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                    reprojectEncoder.endEncoding()
                }
            }

            // Reset the "did anything actually trace this frame" counter via
            // a blit fill — sequenced on this same command buffer ahead of
            // the trace encoder below, so there's no CPU/GPU race the way a
            // raw pointer write to a shared buffer would risk.
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.fill(buffer: activeSampleCounterBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
                blit.endEncoding()
            }

            if let traceEncoder = commandBuffer.makeComputeCommandEncoder() {
                traceEncoder.setComputePipelineState(tracePipeline)
                traceEncoder.setTexture(accumTexture, index: 0)
                traceEncoder.setTexture(statsTexture, index: 1)
                traceEncoder.setTexture(positionTexture, index: 2)
                traceEncoder.setBuffer(vertexBuffer, offset: 0, index: 0)
                traceEncoder.setBuffer(normalBuffer, offset: 0, index: 1)
                traceEncoder.setBuffer(indexBuffer, offset: 0, index: 2)
                traceEncoder.setBuffer(triMatBuffer, offset: 0, index: 3)
                traceEncoder.setBuffer(materialBuffer, offset: 0, index: 4)
                traceEncoder.setBytes(&cameraUniforms, length: MemoryLayout<PTCameraUniforms>.stride, index: 5)
                traceEncoder.setBytes(&sceneUniforms, length: MemoryLayout<PTSceneUniforms>.stride, index: 6)
                traceEncoder.setBuffer(pointLightBuffer, offset: 0, index: 7)
                traceEncoder.setBuffer(lightTreeBuffer, offset: 0, index: 8)
                traceEncoder.setBuffer(lightRefBuffer, offset: 0, index: 9)
                traceEncoder.setBuffer(activeSampleCounterBuffer, offset: 0, index: 10)
                traceEncoder.setBuffer(triToRecordBuffer, offset: 0, index: 11)
                traceEncoder.setBuffer(recordToLeafBuffer, offset: 0, index: 12)
                traceEncoder.setAccelerationStructure(accel, bufferIndex: 13)
                // indexBuffer backs the acceleration structure itself (not
                // passed as a named kernel argument in that role) — Metal
                // still requires it marked resident for the intersector to
                // traverse it. vertexBuffer is now also a direct kernel
                // argument above, but useResource is harmless to keep too.
                traceEncoder.useResource(vertexBuffer, usage: .read)
                traceEncoder.useResource(indexBuffer, usage: .read)

                let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
                let threadgroups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
                traceEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                traceEncoder.endEncoding()
            }

            frameIndex += 1
            // Track the camera basis behind whatever's now in accumTexture/
            // positionTexture, so the *next* camera-only reset has something
            // correct to reproject against.
            previousFrameCamera = cameraUniforms

            commandBuffer.addCompletedHandler { [weak self] _ in
                let count = activeSampleCounterBuffer.contents().load(as: UInt32.self)
                DispatchQueue.main.async { self?.lastActiveSampleCount = Int(count) }
            }
        }

        // Periodically snapshot the accumulation buffer into the denoiser's
        // staging buffer and kick off an async pass. The snapshot blit runs
        // right here, on this queue, alongside the trace/resolve encoders
        // above/below — the one place anything touches `accumTexture`
        // besides the trace kernel itself, so it has to stay ordered against
        // that kernel rather than racing it from another queue.
        if denoiseEnabled, let denoiser, !denoiser.isBusy, frameIndex > 0,
           frameIndex - lastDenoiseTriggerFrame >= Self.denoiseSampleInterval,
           let colorBuffer = denoiser.prepareColorBuffer(width: width, height: height),
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            let bytesPerPixel = MemoryLayout<Float>.stride * 4
            blitEncoder.copy(from: accumTexture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: width, height: height, depth: 1),
                              to: colorBuffer, destinationOffset: 0,
                              destinationBytesPerRow: width * bytesPerPixel,
                              destinationBytesPerImage: width * height * bytesPerPixel)
            blitEncoder.endEncoding()
            lastDenoiseTriggerFrame = frameIndex

            let capturedGeneration = denoiseGeneration
            commandBuffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.denoiseGeneration == capturedGeneration else { return }
                    denoiser.denoiseAsync(width: width, height: height) { [weak self] texture in
                        guard let self, self.denoiseGeneration == capturedGeneration else { return }
                        self.denoisedTexture = texture
                    }
                }
            }
        }

        let resolveSourceTexture = (denoiseEnabled ? denoisedTexture : nil) ?? accumTexture

        if let resolveEncoder = commandBuffer.makeComputeCommandEncoder() {
            resolveEncoder.setComputePipelineState(resolvePipeline)
            resolveEncoder.setTexture(resolveSourceTexture, index: 0)
            resolveEncoder.setTexture(drawable.texture, index: 1)
            var exposure = exposureMultiplier()
            resolveEncoder.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 0)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
            resolveEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            resolveEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        let sampleCountNow = frameIndex
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.onSampleCountChanged?(sampleCountNow, Self.softCapSampleCount)
        }
        commandBuffer.commit()
    }
}
