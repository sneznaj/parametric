import SwiftUI
import MetalKit
import QuartzCore

// MARK: - Filament Host View

/// Custom NSView that hosts the Filament renderer via a CAMetalLayer.
final class FilamentHostView: NSView {

    // Filament bridge objects
    private var engine: OpaquePointer?
    private var swapChain: OpaquePointer?
    private var renderer: OpaquePointer?
    private var scene: OpaquePointer?
    private var camera: OpaquePointer?
    private var filamentView: OpaquePointer?

    // Tracked entities for cleanup
    private var entities: [OpaquePointer?] = []

    // Orbit camera state
    private var cameraTheta: Float = 0.7      // azimuthal angle (radians)
    private var cameraPhi: Float = 0.5        // polar angle (radians)
    private var cameraRadius: Float = 25.0     // distance from target
    private var cameraTarget: (Float, Float, Float) = (0, 0, 0)

    // Mouse tracking
    private var isDragging = false
    private var lastDragPoint: CGPoint = .zero

    // Main-thread render timer (avoiding CVDisplayLink threading issues)
    private var renderTimer: DispatchSourceTimer?
    private var renderTimerActive = false

    // Cached viewport size (updated on main thread only)
    private var cachedWidth: Int32 = 800
    private var cachedHeight: Int32 = 600
    private var cachedScale: CGFloat = 2.0

    // Track whether Filament has been set up (deferred until in window)
    private var filamentSetupDone = false

    // MARK: - Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        configureMetalLayer()
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !filamentSetupDone {
            filamentSetupDone = true
            setupFilament()
            startRenderLoop()
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

    private func configureMetalLayer() {
        let metalLayer: CAMetalLayer
        if let existing = layer as? CAMetalLayer {
            metalLayer = existing
        } else {
            metalLayer = CAMetalLayer()
            layer = metalLayer
            wantsLayer = true
        }
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: - Filament Setup

    private func setupFilament() {
        engine = filament_createEngine()
        guard let eng = engine else {
            print("FilamentRenderView: failed to create Filament engine")
            return
        }

        // Ensure the layer is properly sized before creating swap chain.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        var size = bounds.size
        if size.width < 1 { size.width = 800 }
        if size.height < 1 { size.height = 600 }
        guard let metalLayer = layer as? CAMetalLayer else {
            print("FilamentRenderView: view layer is not a CAMetalLayer")
            return
        }
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Ensure the Metal layer has a device before creating the swap chain.
        if metalLayer.device == nil {
            metalLayer.device = MTLCreateSystemDefaultDevice()
        }

        // Pass the CAMetalLayer directly to Filament instead of the NSView.
        // Filament's createSwapChain dispatches to the engine thread, which must
        // not access NSView (it is main-thread-only). Passing the CAMetalLayer
        // avoids the NSView → layer indirection and thread-safety issue.
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

        // Wire up view.
        filament_viewSetScene(fv, scn)
        filament_viewSetCamera(fv, cam)
        filament_viewSetViewport(fv, 0, 0, cachedWidth, cachedHeight)

        // Enable post-processing (tone mapping) without bloom.
        filament_viewSetPostProcessing(fv, true)

        // Set up three-point studio lighting.
        setupDefaultLighting(engine: eng, scene: scn)

        updateCamera()
    }

    private func setupDefaultLighting(engine: OpaquePointer, scene: OpaquePointer) {
        // Key light: warm directional light from upper-right-front.
        _ = filament_createDirectionalLight(
            engine, scene,
            -0.55, -0.72, 0.41,
            1.0, 0.95, 0.88,
            2000.0,
            false
        )

        // Fill light: cooler, from the opposite side.
        _ = filament_createDirectionalLight(
            engine, scene,
            0.62, -0.25, -0.35,
            0.76, 0.80, 0.90,
            650.0,
            false
        )

        // Rim light: from behind and above.
        _ = filament_createDirectionalLight(
            engine, scene,
            0.0, -0.95, -0.3,
            0.9, 0.9, 0.95,
            500.0,
            false
        )

        // Top fill: soft overhead light.
        _ = filament_createDirectionalLight(
            engine, scene,
            0.0, -1.0, 0.0,
            0.7, 0.72, 0.78,
            300.0,
            false
        )
    }

    private func teardownFilament() {
        // Engine::destroy cleans up all created resources (swap chain, renderer,
        // scene, view, camera, entities, materials, etc.).
        if let eng = engine {
            filament_destroyEngine(eng)
            engine = nil
        }
        swapChain = nil
        renderer = nil
        scene = nil
        camera = nil
        filamentView = nil
        entities.removeAll()
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
        cachedWidth = Int32(size.width * scale)
        cachedHeight = Int32(size.height * scale)
        cachedScale = scale

        filament_viewSetViewport(fv, 0, 0, cachedWidth, cachedHeight)

        if filament_beginFrame(rend, sw) {
            filament_render(rend, fv)
            filament_endFrame(rend)
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

        cameraTheta -= dx * 0.01
        cameraPhi += dy * 0.01
        cameraPhi = max(-1.5, min(1.5, cameraPhi))

        lastDragPoint = point
        updateCamera()
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        cameraRadius *= (1.0 - dy * 0.001)
        cameraRadius = max(0.5, min(200.0, cameraRadius))
        updateCamera()
    }

    override func magnify(with event: NSEvent) {
        cameraRadius *= (1.0 - Float(event.magnification))
        cameraRadius = max(0.5, min(200.0, cameraRadius))
        updateCamera()
    }

    private func updateCamera() {
        guard let cam = camera else { return }
        let (tx, ty, tz) = cameraTarget

        filament_cameraOrbit(cam, cameraTheta, cameraPhi, cameraRadius, tx, ty, tz)

        let size = bounds.size
        let aspect = size.width > 0 ? Float(size.width / size.height) : 1.33
        filament_cameraSetPerspective(cam, 45.0, aspect, 0.1, 1000.0)
    }

    // MARK: - Geometry Population

    /// Replace all geometry in the scene with the given shapes.
    func populate(shapes: [GeometricShape]) {
        guard filamentSetupDone, let eng = engine, let scn = scene else { return }

        // Remove existing entities.
        for entity in entities {
            if let e = entity {
                filament_removeEntity(scn, e)
            }
        }
        entities.removeAll()

        // Compute bounding box for auto-framing.
        let bounds = computeBounds(shapes: shapes)
        let cx = Float(bounds.min.x + bounds.max.x) * 0.5
        let cy = Float(bounds.min.y + bounds.max.y) * 0.5
        let cz = Float(bounds.min.z + bounds.max.z) * 0.5
        let dx = Float(bounds.max.x - bounds.min.x)
        let dy = Float(bounds.max.y - bounds.min.y)
        let dz = Float(bounds.max.z - bounds.min.z)
        let diag = sqrt(dx * dx + dy * dy + dz * dz)
        cameraTarget = (cx, cz, -cy)
        cameraRadius = max(diag * 1.8, 1.0)

        // Create entities for each shape.
        var newEntities: [OpaquePointer?] = []
        for shape in shapes {
            if let entity = makeEntity(engine: eng, scene: scn, shape: shape) {
                newEntities.append(entity)
            }
        }
        entities = newEntities

        updateCamera()
    }

    // MARK: - Shape → Entity Mapping

    private func makeEntity(engine: OpaquePointer,
                            scene: OpaquePointer,
                            shape: GeometricShape) -> OpaquePointer? {
        switch shape {
        case .point(let p):
            return filament_createSphere(engine, scene, nil,
                Float(p.x), Float(p.z), Float(-p.y), 0.16, 32)

        case .sphere(let center, let radius):
            return filament_createSphere(engine, scene, nil,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), 64)

        case .box(let minPt, let maxPt):
            return filament_createBox(engine, scene, nil,
                Float(minPt.x), Float(minPt.z), Float(-minPt.y),
                Float(maxPt.x), Float(maxPt.z), Float(-maxPt.y))

        case .cylinder(let center, let radius, let height):
            return filament_createCylinder(engine, scene, nil,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), Float(height), 64)

        case .cone(let center, let radius, let height):
            return filament_createCone(engine, scene, nil,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(radius), Float(height), 64)

        case .torus(let center, let majorR, let minorR):
            return filament_createTorus(engine, scene, nil,
                Float(center.x), Float(center.z), Float(-center.y),
                Float(majorR), Float(minorR), 96, 32)

        case .circle(let center, let radius):
            return filament_createDisc(engine, scene, nil,
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
                filament_createPolygon(engine, scene, nil,
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
                    filament_createSurfaceStrip(engine, scene, nil,
                        bufA.baseAddress, Int32(curveA.count),
                        bufB.baseAddress, Int32(curveB.count))
                }
            }

        case .line(let start, let end):
            return filament_createLine(engine, scene, nil,
                Float(start.x), Float(start.z), Float(-start.y),
                Float(end.x), Float(end.z), Float(-end.y),
                0.045)

        case .polyline(let points):
            guard points.count >= 2 else { return nil }
            var first: OpaquePointer?
            for i in 0..<(points.count - 1) {
                let a = points[i]
                let b = points[i + 1]
                let entity = filament_createLine(engine, scene, nil,
                    Float(a.x), Float(a.z), Float(-a.y),
                    Float(b.x), Float(b.z), Float(-b.y),
                    0.045)
                if i == 0 { first = entity }
            }
            // Return first entity; we rely on Filament to keep others alive
            // through the scene reference. Entities are cleaned up on repopulate.
            return first

        case .label:
            return nil

        case .painted(let inner, _):
            // Create geometry for the inner shape with default material.
            // Full PBR material support via Material3D can be added by
            // creating a custom material instance per shape.
            return makeEntity(engine: engine, scene: scene, shape: inner)
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
            case .label(_, let p):
                expand(p)
            case .painted(let inner, _):
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
struct FilamentRenderView: NSViewRepresentable {
    let shapes: [GeometricShape]

    func makeNSView(context: Context) -> FilamentHostView {
        let hostView = FilamentHostView(frame: .zero)
        hostView.autoresizingMask = [.width, .height]
        return hostView
    }

    func updateNSView(_ nsView: FilamentHostView, context: Context) {
        nsView.populate(shapes: shapes)
    }
}
