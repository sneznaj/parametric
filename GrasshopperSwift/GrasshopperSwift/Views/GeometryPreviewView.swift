import SwiftUI
import UniformTypeIdentifiers

// MARK: - View Mode

enum ViewMode: String, CaseIterable {
    case twoD          = "2D"
    case top           = "Top (XY)"
    case front         = "Front (XZ)"
    case right         = "Right (YZ)"
    case perspective   = "Perspective"
    case realistic     = "Realistic"
    case ultraRealistic = "Ultra Realistic"
}

enum RealisticInteractionMode: String, CaseIterable {
    case viewport = "Viewport"
    case object = "Object"
}

enum Export3DFormat: String, CaseIterable {
    case obj, stl, ply, gltf, collada, fbx, usda, usdz, step, iges, threeMF

    var menuTitle: String {
        switch self {
        case .obj:      return "Wavefront OBJ (.obj)"
        case .stl:      return "STL (.stl)"
        case .ply:      return "PLY (.ply)"
        case .gltf:     return "glTF / GLB (.glb)"
        case .collada:  return "Collada (.dae)"
        case .fbx:      return "FBX (.fbx)"
        case .usda:     return "USD (.usda)"
        case .usdz:     return "USDZ (.usdz)"
        case .step:     return "STEP (.step)"
        case .iges:     return "IGES (.iges)"
        case .threeMF:  return "3MF (.3mf)"
        }
    }

    var fileExtension: String {
        switch self {
        case .obj:      return "obj"
        case .stl:      return "stl"
        case .ply:      return "ply"
        case .gltf:     return "glb"
        case .collada:  return "dae"
        case .fbx:      return "fbx"
        case .usda:     return "usda"
        case .usdz:     return "usdz"
        case .step:     return "step"
        case .iges:     return "iges"
        case .threeMF:  return "3mf"
        }
    }

    var utType: UTType {
        switch self {
        case .obj:      return .objFile
        case .stl:      return .stlFile
        case .ply:      return .plyFile
        case .gltf:     return .glbFile
        case .collada:  return .daeFile
        case .fbx:      return .fbxFile
        case .usda:     return .usdaFile
        case .usdz:     return .usdzFile
        case .step:     return .stepFile
        case .iges:     return .igesFile
        case .threeMF:  return .threeMFFile
        }
    }
}

extension ViewMode {
    /// True if `current` and `target` sit on opposite sides of the 2D/3D pipeline split.
    /// 2D and 3D nodes can't coexist in a project, so crossing this boundary is only
    /// allowed while the project has no nodes yet.
    static func crossesPipelineBoundary(from current: ViewMode, to target: ViewMode) -> Bool {
        (current == .twoD) != (target == .twoD)
    }
}

let kViewModeKey = "geometryPreviewViewMode"
let kShow2DPreviewGridKey = "show2DPreviewGrid"
let kShow2DPreviewAxesKey = "show2DPreviewAxes"

struct GeometryPreviewView: View {
    @EnvironmentObject var workspace: WorkspaceManager

    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var zoom: CGFloat = 30       // pixels per world unit
    @State private var lastZoom: CGFloat = 30

    // Orbit camera for Perspective mode (radians). Azimuth rotates around
    // world Z (up); elevation tilts up/down from the horizontal plane.
    @State private var camAzimuth: Double = Self.defaultCamAzimuth
    @State private var camElevation: Double = Self.defaultCamElevation
    @State private var lastCamAzimuth: Double = Self.defaultCamAzimuth
    @State private var lastCamElevation: Double = Self.defaultCamElevation
    @State private var realisticInteractionMode: RealisticInteractionMode = .viewport
    private static let defaultCamAzimuth: Double = 225 * .pi / 180
    private static let defaultCamElevation: Double = 30 * .pi / 180

    // Ultra Realistic (Metal path tracer) progress state.
    @State private var ultraSampleCount: Int = 0
    @State private var ultraTargetSampleCount: Int = 1
    @State private var ultraResetToken: Int = 0
    @AppStorage("ultraDenoiseEnabled") private var ultraDenoiseEnabled: Bool = true
    @AppStorage("ultraNoiseTarget") private var ultraNoiseTarget: Double = 0.03
    @AppStorage("ultraAllowExtendedSampling") private var ultraAllowExtendedSampling: Bool = true
    @State private var showUltraSettings = false

    @AppStorage(kViewModeKey) private var storedViewMode: String = ViewMode.perspective.rawValue
    @AppStorage(kShow2DPreviewGridKey) private var show2DPreviewGrid = false
    @AppStorage(kShow2DPreviewAxesKey) private var show2DPreviewAxes = false

    private var viewMode: ViewMode {
        ViewMode(rawValue: storedViewMode) ?? .perspective
    }

    /// Shapes to draw for the current view mode — 2D mode shows only 2D-pipeline shapes,
    /// every other mode (top/front/right/perspective/realistic) shows only 3D geometry.
    private var modeShapes: [GeometricShape] {
        workspace.activePreviewShapes.filter { $0.isStyled2D == (viewMode == .twoD) }
    }

    /// Tracked shapes for the realistic (Filament) renderer, filtered to 3D-pipeline geometry only.
    private var modeTrackedShapes: [TrackedShape] {
        workspace.activeTrackedShapes.filter { !$0.shape.isStyled2D }
    }

    /// View modes offered in the toolbar picker — 2D mode only offers 2D (no 3D camera
    /// angles), and every other mode only offers the 3D camera angles (no 2D).
    private var pickerModes: [ViewMode] {
        viewMode == .twoD ? [.twoD] : ViewMode.allCases.filter { $0 != .twoD }
    }

    // World-space light direction (normalized): upper-right-front
    // L = normalize(0.5, 0.3, 1.0)
    private let kLx = 0.4303, kLy = 0.2582, kLz = 0.8607
    private let kAmbient: Double = 0.15

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { _ in
                if viewMode == .realistic {
                    FilamentRenderView(
                        shapes: modeTrackedShapes,
                        renderConfig: workspace.activeRenderConfig,
                        interactionMode: realisticInteractionMode
                    )
                } else if viewMode == .ultraRealistic {
                    UltraRealisticRenderView(
                        shapes: modeTrackedShapes,
                        renderConfig: workspace.activeRenderConfig,
                        sampleCount: $ultraSampleCount,
                        targetSampleCount: $ultraTargetSampleCount,
                        resetToken: ultraResetToken,
                        denoiseEnabled: ultraDenoiseEnabled,
                        noiseTarget: ultraNoiseTarget,
                        allowExtendedSampling: ultraAllowExtendedSampling
                    )
                } else {
                    Canvas { ctx, size in
                        let center = CGPoint(
                            x: size.width  / 2 + pan.width,
                            y: size.height / 2 + pan.height
                        )
                        drawBackground(ctx: ctx, size: size)
                        if viewMode != .twoD || show2DPreviewGrid {
                            drawGrid(ctx: ctx, size: size, center: center)
                        }
                        if viewMode != .twoD || show2DPreviewAxes {
                            drawAxes(ctx: ctx, size: size, center: center)
                        }
                        for shape in modeShapes {
                            draw(ctx: ctx, shape: shape, center: center)
                        }
                        if modeShapes.isEmpty {
                            drawEmptyState(ctx: ctx, size: size)
                        }
                    }
                    .gesture(canvasDragGesture)
                    .gesture(zoomGesture)
                }
            }
            statusBar
        }
        .preferredColorScheme(.dark)
        .background(Color(white: 0.09))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.3.layers.3d")
                .foregroundStyle(.teal)
                .font(.system(size: 13, weight: .semibold))
            if pickerModes.count > 1 {
                Picker("", selection: Binding<ViewMode>(
                    get: { viewMode },
                    set: { storedViewMode = $0.rawValue }
                )) {
                    ForEach(pickerModes, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)
            }
            Spacer()
            if viewMode == .twoD {
                Button {
                    exportSVG()
                } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Export 2D view as SVG")
                .disabled(modeShapes.isEmpty)
            } else {
                Menu {
                    ForEach(Export3DFormat.allCases, id: \.self) { format in
                        Button(format.menuTitle) { export3D(format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Export 3D geometry")
                .disabled(modeShapes.isEmpty)
            }
            if viewMode == .realistic {
                Picker("", selection: $realisticInteractionMode) {
                    ForEach(RealisticInteractionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .accessibilityLabel("Realistic view drag target")
                .help("Viewport moves only the camera. Object rotates only the rendered geometry.")
            }
            if viewMode == .ultraRealistic {
                ProgressView(value: Double(ultraSampleCount), total: Double(max(ultraTargetSampleCount, 1)))
                    .frame(width: 100)
                Text("\(ultraSampleCount)/\(ultraTargetSampleCount) samples")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("Denoise", isOn: $ultraDenoiseEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Periodically refine the preview with Intel Open Image Denoise (Metal/GPU)")
                Button {
                    ultraResetToken += 1
                } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Restart the path-traced render")
                Button {
                    showUltraSettings.toggle()
                } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("Path Tracer Settings")
                .popover(isPresented: $showUltraSettings) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Path Tracer Settings").font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Noise Target: \(ultraNoiseTarget, specifier: "%.2f")")
                                .font(.system(size: 11))
                            Slider(value: $ultraNoiseTarget, in: 0.01...0.10)
                                .frame(width: 200)
                        }
                        Toggle("Extend sampling for noisy areas", isOn: $ultraAllowExtendedSampling)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                    .padding(14)
                }
            }
            if viewMode != .realistic && viewMode != .ultraRealistic {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        pan = .zero; panAnchor = .zero
                        zoom = 30; lastZoom = 30
                        camAzimuth = Self.defaultCamAzimuth; camElevation = Self.defaultCamElevation
                        lastCamAzimuth = Self.defaultCamAzimuth; lastCamElevation = Self.defaultCamElevation
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Reset view")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(modeShapes.isEmpty ? Color.red : Color.green)
                .frame(width: 6, height: 6)
            Text(modeShapes.isEmpty
                 ? "No geometry — add a \(viewMode == .twoD ? "2D" : "geometry") node"
                 : "\(modeShapes.count) object\(modeShapes.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(viewMode.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Divider().frame(height: 10)
            if viewMode == .realistic {
                Text(realisticInteractionMode == .object
                     ? "Drag to rotate objects  ·  Pinch / scroll to zoom"
                     : "Drag to orbit  ·  Pinch / scroll to zoom")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if viewMode == .ultraRealistic {
                Text(ultraSampleCount >= ultraTargetSampleCount
                     ? "Converged  ·  Drag to orbit  ·  Pinch / scroll to zoom"
                     : "Rendering…  ·  Drag to orbit  ·  Pinch / scroll to zoom")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                if viewMode == .perspective {
                    Text("Drag to orbit  ·  ⌘-drag to pan")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(String(format: "%.0f%%", zoom / 30 * 100))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Gestures

    /// Drag to orbit the camera in Perspective mode; ⌘-drag (or dragging in
    /// any other Canvas-rendered mode) pans instead, matching the Realistic
    /// (Filament) renderer's "drag orbits, ⌘-drag pans" convention.
    private var canvasDragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                if viewMode == .perspective && !NSEvent.modifierFlags.contains(.command) {
                    camAzimuth = lastCamAzimuth - v.translation.width * 0.01
                    camElevation = max(-1.48, min(1.48, lastCamElevation + v.translation.height * 0.01))
                } else {
                    pan = CGSize(width:  panAnchor.width  + v.translation.width,
                                 height: panAnchor.height + v.translation.height)
                }
            }
            .onEnded { _ in
                lastCamAzimuth = camAzimuth
                lastCamElevation = camElevation
                panAnchor = pan
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in zoom = max(4, min(600, lastZoom * v)) }
            .onEnded   { _ in lastZoom = zoom }
    }

    // MARK: - Perspective Orbit Camera

    /// Camera basis for Perspective mode, built from `camAzimuth`/`camElevation`.
    /// `right`/`up` span the screen plane; `dir` points from the target toward
    /// the camera and doubles as the view direction for face culling/depth sort.
    private var perspectiveCameraBasis: (right: Point3D, up: Point3D, dir: Point3D) {
        let cosA = cos(camAzimuth), sinA = sin(camAzimuth)
        let cosE = cos(camElevation), sinE = sin(camElevation)
        return (
            right: Point3D(x: -sinA, y: cosA, z: 0),
            up:    Point3D(x: -sinE * cosA, y: -sinE * sinA, z: cosE),
            dir:   Point3D(x: cosE * cosA, y: cosE * sinA, z: sinE)
        )
    }

    private func dotProduct(_ a: Point3D, _ b: Point3D) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    // MARK: - Projection

    private func project(_ p: Point3D, center: CGPoint) -> CGPoint {
        switch viewMode {
        case .twoD:
            return CGPoint(x: center.x + p.x * zoom, y: center.y - p.y * zoom)
        case .top:
            return CGPoint(x: center.x + p.x * zoom, y: center.y - p.y * zoom)
        case .front:
            return CGPoint(x: center.x + p.x * zoom, y: center.y - p.z * zoom)
        case .right:
            return CGPoint(x: center.x + p.y * zoom, y: center.y - p.z * zoom)
        case .perspective:
            let basis = perspectiveCameraBasis
            let sx = dotProduct(p, basis.right)
            let sy = -dotProduct(p, basis.up)
            return CGPoint(x: center.x + sx * zoom, y: center.y + sy * zoom)
        case .realistic, .ultraRealistic:
            let c30 = cos(Double.pi / 6), s30 = sin(Double.pi / 6)
            let sx = (p.x - p.y) * c30
            let sy = (p.x + p.y) * s30 - p.z
            return CGPoint(x: center.x + sx * zoom, y: center.y + sy * zoom)
        }
    }

    // MARK: - Lighting Helpers

    /// Lambert + ambient brightness in [0, 1]
    private func lambert(nx: Double, ny: Double, nz: Double) -> Double {
        let d = max(0.0, nx * kLx + ny * kLy + nz * kLz)
        return kAmbient + (1.0 - kAmbient) * d
    }

    /// Back-face cull: true if face normal points toward the camera
    private func isFrontFacing(nx: Double, ny: Double, nz: Double) -> Bool {
        let dot: Double
        switch viewMode {
        case .twoD:                  return true
        case .top:                   dot =  nz
        case .front:                 dot =  ny
        case .right:                 dot =  nx
        case .perspective:
            let d = perspectiveCameraBasis.dir
            dot = nx * d.x + ny * d.y + nz * d.z
        case .realistic, .ultraRealistic: dot =  nx + ny + nz
        }
        return dot > -0.01
    }

    /// Depth value for painter's algorithm — smaller = farther = drawn first
    private func painterDepth(_ p: Point3D) -> Double {
        switch viewMode {
        case .twoD:                  return 0
        case .top:                   return  p.z
        case .front:                 return  p.y
        case .right:                 return  p.x
        case .perspective:            return  dotProduct(p, perspectiveCameraBasis.dir)
        case .realistic, .ultraRealistic: return  p.x + p.y + p.z
        }
    }

    /// Screen-space unit vector pointing toward the light source
    private func screenLightDir() -> CGPoint {
        if viewMode == .twoD { return CGPoint(x: 0, y: -1) }
        let sp = project(Point3D(x: kLx, y: kLy, z: kLz), center: .zero)
        let len = hypot(sp.x, sp.y)
        guard len > 0.001 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: sp.x / len, y: sp.y / len)
    }

    // MARK: - Grid

    private func gridStep() -> Double {
        let target: Double = 70
        let rawStep = target / zoom
        let exp = floor(log10(rawStep))
        let base = pow(10, exp)
        let norm = rawStep / base
        if norm < 2 { return base }
        if norm < 5 { return 2 * base }
        return 5 * base
    }

    private func drawBackground(ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.09)))
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize, center: CGPoint) {
        let step = gridStep()
        let majorEvery = 5
        let n = Int((max(size.width, size.height) / zoom / step).rounded(.up)) + 2

        for i in -n...n {
            let coord = Double(i) * step
            let isMajor = (i % majorEvery) == 0
            let (hStart, hEnd, vStart, vEnd): (Point3D, Point3D, Point3D, Point3D)
            let lim = Double(n) * step

            switch viewMode {
            case .twoD, .top:
                hStart = Point3D(x: -lim, y: coord, z: 0);  hEnd = Point3D(x: lim, y: coord, z: 0)
                vStart = Point3D(x: coord, y: -lim, z: 0);  vEnd = Point3D(x: coord, y: lim, z: 0)
            case .front:
                hStart = Point3D(x: -lim, y: 0, z: coord);  hEnd = Point3D(x: lim, y: 0, z: coord)
                vStart = Point3D(x: coord, y: 0, z: -lim);  vEnd = Point3D(x: coord, y: 0, z: lim)
            case .right:
                hStart = Point3D(x: 0, y: -lim, z: coord);  hEnd = Point3D(x: 0, y: lim, z: coord)
                vStart = Point3D(x: 0, y: coord, z: -lim);  vEnd = Point3D(x: 0, y: coord, z: lim)
            case .perspective, .realistic, .ultraRealistic:
                hStart = Point3D(x: -lim, y: coord, z: 0);  hEnd = Point3D(x: lim, y: coord, z: 0)
                vStart = Point3D(x: coord, y: -lim, z: 0);  vEnd = Point3D(x: coord, y: lim, z: 0)
            }

            let alpha: Double = isMajor ? 0.16 : 0.07
            var hp = Path()
            hp.move(to: project(hStart, center: center))
            hp.addLine(to: project(hEnd, center: center))
            var vp = Path()
            vp.move(to: project(vStart, center: center))
            vp.addLine(to: project(vEnd, center: center))
            ctx.stroke(hp, with: .color(.white.opacity(alpha)), lineWidth: 0.5)
            ctx.stroke(vp, with: .color(.white.opacity(alpha)), lineWidth: 0.5)
        }
    }

    // MARK: - Axes

    private func drawAxes(ctx: GraphicsContext, size: CGSize, center: CGPoint) {
        // Use the smaller dimension so the gizmo (and its labels) always stay within
        // the canvas bounds — sizing off the larger dimension made the vertical Z arrow
        // overshoot the top edge on wide/landscape windows, clipping its label entirely.
        let len = Double(min(size.width, size.height)) / zoom * 0.35
        struct Axis { let end: Point3D; let color: Color; let label: String }

        let axes: [Axis]
        switch viewMode {
        case .twoD, .top:
            axes = [Axis(end: Point3D(x: len, y: 0, z: 0), color: .red,   label: "X"),
                    Axis(end: Point3D(x: 0, y: len, z: 0), color: .green, label: "Y")]
        case .front:
            axes = [Axis(end: Point3D(x: len, y: 0, z: 0), color: .red,  label: "X"),
                    Axis(end: Point3D(x: 0, y: 0, z: len), color: .blue, label: "Z")]
        case .right:
            axes = [Axis(end: Point3D(x: 0, y: len, z: 0), color: .green, label: "Y"),
                    Axis(end: Point3D(x: 0, y: 0, z: len), color: .blue,  label: "Z")]
        case .perspective, .realistic, .ultraRealistic:
            axes = [Axis(end: Point3D(x: len, y: 0, z: 0), color: .red,   label: "X"),
                    Axis(end: Point3D(x: 0, y: len, z: 0), color: .green, label: "Y"),
                    Axis(end: Point3D(x: 0, y: 0, z: len), color: .blue,  label: "Z")]
        }

        let origin = project(.zero, center: center)
        ctx.fill(Path(ellipseIn: CGRect(x: origin.x-3, y: origin.y-3, width: 6, height: 6)),
                 with: .color(.white.opacity(0.4)))

        for axis in axes {
            let tip = project(axis.end, center: center)
            var path = Path()
            path.move(to: origin); path.addLine(to: tip)
            ctx.stroke(path, with: .color(axis.color.opacity(0.85)), lineWidth: 1.5)
            let dx = tip.x - origin.x, dy = tip.y - origin.y
            let l2 = sqrt(dx*dx + dy*dy)
            if l2 > 0 {
                let nx = dx/l2, ny = dy/l2, al: CGFloat = 9
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - nx*al + ny*3.5, y: tip.y - ny*al - nx*3.5))
                arrow.addLine(to: CGPoint(x: tip.x - nx*al - ny*3.5, y: tip.y - ny*al + nx*3.5))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(axis.color.opacity(0.85)))
            }
            ctx.draw(
                Text(axis.label).font(.system(size: 11, weight: .bold)).foregroundColor(axis.color),
                at: CGPoint(x: tip.x + 10, y: tip.y - 8)
            )
        }
    }

    // MARK: - Shape Dispatch

    private func draw(ctx: GraphicsContext, shape: GeometricShape, center: CGPoint) {
        if case .painted(let inner, let material) = shape {
            draw(ctx: ctx, shape: inner, center: center, tint: (material.r, material.g, material.b))
            return
        }
        if case .styled2D = shape {
            draw(ctx: ctx, shape: shape, center: center, tint: nil)
            return
        }
        draw(ctx: ctx, shape: shape, center: center, tint: nil)
    }

    private func draw(ctx: GraphicsContext,
                      shape: GeometricShape,
                      center: CGPoint,
                      tint: (r: Double, g: Double, b: Double)?) {
        switch shape {

        case .point(let p):
            let sp = project(p, center: center)
            let tint = tint ?? renderedColor(from: shape, fallback: (1.0, 0.95, 0.3))
            // Glow halo
            var glow = ctx; glow.opacity = 0.2
            glow.fill(Path(ellipseIn: CGRect(x: sp.x-10, y: sp.y-10, width: 20, height: 20)),
                      with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)))
            // Core radial
            ctx.fill(Path(ellipseIn: CGRect(x: sp.x-5, y: sp.y-5, width: 10, height: 10)),
                     with: .radialGradient(
                        Gradient(colors: [.white, Color(red: tint.r, green: tint.g, blue: tint.b), .orange]),
                        center: sp, startRadius: 0, endRadius: 6
                     ))

        case .line(let a, let b):
            let pa = project(a, center: center), pb = project(b, center: center)
            let tint = tint ?? renderedColor(from: shape, fallback: (0.4, 0.95, 1.0))
            var path = Path(); path.move(to: pa); path.addLine(to: pb)
            var glow = ctx; glow.opacity = 0.18
            glow.stroke(path, with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)), lineWidth: 6)
            ctx.stroke(path, with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)), lineWidth: 1.6)
            drawDot(ctx: ctx, at: pa, color: Color(red: tint.r, green: tint.g, blue: tint.b), r: 3.5)
            drawDot(ctx: ctx, at: pb, color: Color(red: tint.r, green: tint.g, blue: tint.b), r: 3.5)

        case .polyline(let pts):
            guard pts.count > 1 else { return }
            let tint = tint ?? renderedColor(from: shape, fallback: (0.45, 0.82, 1.0))
            let spts = pts.map { project($0, center: center) }
            var path = Path(); path.move(to: spts[0])
            for pt in spts.dropFirst() { path.addLine(to: pt) }
            var glow = ctx; glow.opacity = 0.14
            glow.stroke(path, with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)), lineWidth: 5)
            ctx.stroke(path, with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)), lineWidth: 1.4)

        case .polygon(let pts):
            guard pts.count > 2 else { return }
            let tint = tint ?? renderedColor(from: shape, fallback: (0.18, 0.65, 0.24))
            let spts = pts.map { project($0, center: center) }
            var path = Path(); path.move(to: spts[0])
            for pt in spts.dropFirst() { path.addLine(to: pt) }
            path.closeSubpath()
            let minX = spts.map(\.x).min()!, maxX = spts.map(\.x).max()!
            let minY = spts.map(\.y).min()!, maxY = spts.map(\.y).max()!
            let cx2 = (minX + maxX) / 2, cy2 = (minY + maxY) / 2
            let ld = screenLightDir()
            let span: CGFloat = max(maxX - minX, maxY - minY)
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [
                    Color(red: tint.r * 0.28, green: tint.g * 0.28, blue: tint.b * 0.28),
                    Color(red: tint.r, green: tint.g, blue: tint.b),
                    Color(red: min(1, tint.r * 1.35), green: min(1, tint.g * 1.35), blue: min(1, tint.b * 1.35)),
                ]),
                startPoint: CGPoint(x: cx2 - ld.x * span * 0.7, y: cy2 - ld.y * span * 0.7),
                endPoint:   CGPoint(x: cx2 + ld.x * span * 0.7, y: cy2 + ld.y * span * 0.7)
            ))
            var glow = ctx; glow.opacity = 0.28
            glow.stroke(path, with: .color(Color(red: tint.r, green: tint.g, blue: tint.b)), lineWidth: 3)
            ctx.stroke(path, with: .color(Color(red: tint.r * 0.6, green: tint.g * 0.6, blue: tint.b * 0.6)), lineWidth: 1.2)

        case .surfaceStrip(let curveA, let curveB):
            drawSurfaceStrip(ctx: ctx,
                             curveA: curveA,
                             curveB: curveB,
                             center: center,
                             baseColor: tint ?? renderedColor(from: shape, fallback: (0.30, 0.74, 0.88)))

        case .circle(let c, let r):
            let tint = tint ?? renderedColor(from: shape, fallback: (0.18, 0.88, 0.98))
            drawDisc(ctx: ctx, worldCenter: c, worldRadius: r, canvasCenter: center,
                     br: tint.r, bg: tint.g, bb: tint.b)

        case .sphere(let c, let r):
            let tint = tint ?? renderedColor(from: shape, fallback: (0.52, 0.18, 0.78))
            drawSphere(ctx: ctx, worldCenter: c, worldRadius: r, canvasCenter: center,
                       baseColor: tint)

        case .box(let mn, let mx):
            drawBox(ctx: ctx, mn: mn, mx: mx, center: center,
                    baseColor: tint ?? renderedColor(from: shape, fallback: (1.0, 0.55, 0.15)))

        case .cylinder(let c, let r, let h):
            drawCylinder(ctx: ctx, worldCenter: c, radius: r, height: h, canvasCenter: center,
                         baseColor: tint ?? renderedColor(from: shape, fallback: (0.15, 0.72, 0.62)))

        case .cone(let c, let r, let h):
            drawCone(ctx: ctx, worldCenter: c, radius: r, height: h, canvasCenter: center,
                     baseColor: tint ?? renderedColor(from: shape, fallback: (1.0, 0.62, 0.04)))

        case .torus(let c, let majorR, let minorR):
            drawTorus(ctx: ctx, worldCenter: c, majorR: majorR, minorR: minorR, canvasCenter: center,
                      baseColor: tint ?? renderedColor(from: shape, fallback: (0.22, 0.84, 0.76)))

        case .mesh(let verts, let tris):
            drawMesh(ctx: ctx, vertices: verts, triangleIndices: tris, center: center,
                     baseColor: tint ?? renderedColor(from: shape, fallback: (0.62, 0.68, 0.78)))

        case .spline(let cps, let degree, let closed):
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed)
            draw(ctx: ctx, shape: .polyline(pts), center: center,
                 tint: tint ?? renderedColor(from: shape, fallback: (0.62, 0.42, 0.98)))

        case .label(let text, let p):
            let sp = project(p, center: center)
            ctx.draw(
                Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.75)),
                at: CGPoint(x: sp.x, y: sp.y - 10)
            )

        case .styled2D(let inner, let style):
            draw2DStyled(ctx: ctx, shape: inner, style: style, center: center)

        case .painted(let inner, let material):
            draw(ctx: ctx, shape: inner, center: center, tint: (material.r, material.g, material.b))
        }
    }

    // MARK: - 2D Styled Renderer

    private func draw2DStyled(ctx: GraphicsContext,
                               shape: GeometricShape,
                               style: Shape2DStyle,
                               center: CGPoint) {
        let strokeColor = Color(red: style.strokeR, green: style.strokeG, blue: style.strokeB)
        let fillColor   = Color(red: style.fillR, green: style.fillG, blue: style.fillB)
        let lineWidth   = CGFloat(style.strokeThickness)

        switch shape {
        case .point(let p):
            let sp = project(p, center: center)
            let r = max(2, lineWidth * 1.8)
            // Glow
            var glow = ctx; glow.opacity = 0.22
            glow.fill(Path(ellipseIn: CGRect(x: sp.x - r*1.8, y: sp.y - r*1.8, width: r*3.6, height: r*3.6)),
                      with: .color(strokeColor))
            // Core
            ctx.fill(Path(ellipseIn: CGRect(x: sp.x - r, y: sp.y - r, width: r*2, height: r*2)),
                     with: .color(strokeColor))

        case .line(let a, let b):
            let pa = project(a, center: center), pb = project(b, center: center)
            var path = Path(); path.move(to: pa); path.addLine(to: pb)
            ctx.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
            // Endpoint dots
            let dotR = max(2, lineWidth * 0.9)
            ctx.fill(Path(ellipseIn: CGRect(x: pa.x-dotR, y: pa.y-dotR, width: dotR*2, height: dotR*2)),
                     with: .color(strokeColor))
            ctx.fill(Path(ellipseIn: CGRect(x: pb.x-dotR, y: pb.y-dotR, width: dotR*2, height: dotR*2)),
                     with: .color(strokeColor))

        case .polygon(let pts):
            guard pts.count > 2 else { return }
            let spts = pts.map { project($0, center: center) }
            var path = Path(); path.move(to: spts[0])
            for pt in spts.dropFirst() { path.addLine(to: pt) }
            path.closeSubpath()
            if style.fillEnabled {
                ctx.fill(path, with: .color(fillColor.opacity(0.92)))
            }
            ctx.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)

        case .polyline(let pts):
            guard pts.count > 1 else { return }
            let spts = pts.map { project($0, center: center) }
            if style.fillEnabled {
                var fillPath = Path(); fillPath.move(to: spts[0])
                for pt in spts.dropFirst() { fillPath.addLine(to: pt) }
                fillPath.closeSubpath()
                ctx.fill(fillPath, with: .color(fillColor.opacity(0.92)))
            }
            var strokePath = Path(); strokePath.move(to: spts[0])
            for pt in spts.dropFirst() { strokePath.addLine(to: pt) }
            ctx.stroke(strokePath, with: .color(strokeColor), lineWidth: lineWidth)

        case .spline(let cps, let degree, let closed):
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed)
            draw2DStyled(ctx: ctx, shape: .polyline(pts), style: style, center: center)

        case .painted(let inner, _):
            // Unwrap painted layer to get the raw shape for 2D rendering
            draw2DStyled(ctx: ctx, shape: inner, style: style, center: center)

        default:
            break
        }
    }

    // MARK: - Solid Shape Renderers

    /// Filled disc with radial Phong-like gradient (used for circles and caps)
    private func drawDisc(ctx: GraphicsContext, worldCenter: Point3D, worldRadius: Double,
                          canvasCenter: CGPoint, br: Double, bg: Double, bb: Double) {
        let segs = min(180, max(36, Int(2 * .pi * worldRadius * zoom / 3)))
        var path = Path()
        let pts = (0...segs).map { i -> CGPoint in
            let a = Double(i) / Double(segs) * 2 * .pi
            return project(Point3D(x: worldCenter.x + worldRadius * cos(a),
                                   y: worldCenter.y + worldRadius * sin(a),
                                   z: worldCenter.z), center: canvasCenter)
        }
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()

        let sc = project(worldCenter, center: canvasCenter)
        let sr = CGFloat(worldRadius * Double(zoom))
        let ld = screenLightDir()
        let hiPt = CGPoint(x: sc.x + ld.x * sr * 0.38, y: sc.y + ld.y * sr * 0.38)

        ctx.fill(path, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: min(1, br*1.8+0.35), green: min(1, bg*1.4+0.25), blue: min(1, bb*1.2+0.2)), location: 0.0),
                .init(color: Color(red: br, green: bg, blue: bb), location: 0.38),
                .init(color: Color(red: br*0.5, green: bg*0.5, blue: bb*0.5), location: 0.75),
                .init(color: Color(red: br*0.12, green: bg*0.12, blue: bb*0.12), location: 1.0),
            ]),
            center: hiPt, startRadius: 0, endRadius: sr * 1.5
        ))
        ctx.stroke(path, with: .color(Color(red: br*0.4, green: bg*0.4, blue: bb*0.4, opacity: 0.6)), lineWidth: 0.8)
    }

    private func drawSphere(ctx: GraphicsContext, worldCenter: Point3D, worldRadius: Double,
                            canvasCenter: CGPoint, baseColor: (r: Double, g: Double, b: Double)) {
        let sc = project(worldCenter, center: canvasCenter)
        let sr = CGFloat(worldRadius * Double(zoom))
        let rect = CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2)
        let circlePath = Path(ellipseIn: rect)

        let ld = screenLightDir()
        // Specular highlight offset — 38% of radius toward light
        let hiPt = CGPoint(x: sc.x + ld.x * sr * 0.38, y: sc.y + ld.y * sr * 0.38)

        // Main fill: specular → lit purple → mid → shadow
        ctx.fill(circlePath, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(white: 0.98, opacity: 0.92), location: 0.0),
                .init(color: Color(red: min(1, baseColor.r * 1.45 + 0.08), green: min(1, baseColor.g * 1.45 + 0.08), blue: min(1, baseColor.b * 1.45 + 0.08)), location: 0.14),
                .init(color: Color(red: baseColor.r, green: baseColor.g, blue: baseColor.b), location: 0.48),
                .init(color: Color(red: baseColor.r * 0.32, green: baseColor.g * 0.32, blue: baseColor.b * 0.32), location: 0.82),
                .init(color: Color(red: baseColor.r * 0.12, green: baseColor.g * 0.12, blue: baseColor.b * 0.12), location: 1.0),
            ]),
            center: hiPt, startRadius: 0, endRadius: sr * 1.55
        ))

        // Rim glow
        var rim = ctx; rim.opacity = 0.4
        rim.stroke(circlePath, with: .color(Color(red: min(1, baseColor.r * 1.3),
                                                   green: min(1, baseColor.g * 1.3),
                                                   blue: min(1, baseColor.b * 1.3))), lineWidth: 1.4)

        // Equator line for depth cue
        let eqH = sr * 0.26
        let eqPath = Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - eqH, width: sr * 2, height: eqH * 2))
        var eq = ctx; eq.opacity = 0.14
        eq.stroke(eqPath, with: .color(.white), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
    }

    private func drawBox(ctx: GraphicsContext, mn: Point3D, mx: Point3D, center: CGPoint,
                         baseColor: (r: Double, g: Double, b: Double)) {
        let corners: [Point3D] = [
            Point3D(x: mn.x, y: mn.y, z: mn.z), // 0
            Point3D(x: mx.x, y: mn.y, z: mn.z), // 1
            Point3D(x: mx.x, y: mx.y, z: mn.z), // 2
            Point3D(x: mn.x, y: mx.y, z: mn.z), // 3
            Point3D(x: mn.x, y: mn.y, z: mx.z), // 4
            Point3D(x: mx.x, y: mn.y, z: mx.z), // 5
            Point3D(x: mx.x, y: mx.y, z: mx.z), // 6
            Point3D(x: mn.x, y: mx.y, z: mx.z), // 7
        ]

        struct BoxFace { let verts: [Int]; let nx, ny, nz: Double }
        let faces: [BoxFace] = [
            BoxFace(verts: [4,5,6,7], nx:  0, ny:  0, nz:  1),  // top
            BoxFace(verts: [0,3,2,1], nx:  0, ny:  0, nz: -1),  // bottom
            BoxFace(verts: [1,2,6,5], nx:  1, ny:  0, nz:  0),  // +X
            BoxFace(verts: [0,4,7,3], nx: -1, ny:  0, nz:  0),  // -X
            BoxFace(verts: [2,3,7,6], nx:  0, ny:  1, nz:  0),  // +Y
            BoxFace(verts: [0,1,5,4], nx:  0, ny: -1, nz:  0),  // -Y
        ]

        let visible = faces.filter { isFrontFacing(nx: $0.nx, ny: $0.ny, nz: $0.nz) }
        let sorted  = visible.sorted {
            let da = $0.verts.reduce(0.0) { $0 + painterDepth(corners[$1]) } / Double($0.verts.count)
            let db = $1.verts.reduce(0.0) { $0 + painterDepth(corners[$1]) } / Double($1.verts.count)
            return da < db
        }

        for face in sorted {
            let br = lambert(nx: face.nx, ny: face.ny, nz: face.nz)
            let r = min(1.0, baseColor.r * br + 0.04)
            let g = min(1.0, baseColor.g * br + 0.04)
            let b = min(1.0, baseColor.b * br + 0.04)

            var path = Path()
            let pts = face.verts.map { project(corners[$0], center: center) }
            path.move(to: pts[0])
            for pt in pts.dropFirst() { path.addLine(to: pt) }
            path.closeSubpath()

            ctx.fill(path, with: .color(Color(red: r, green: g, blue: b)))
            ctx.stroke(path, with: .color(Color(red: r*0.45, green: g*0.45, blue: b*0.45, opacity: 0.9)),
                       lineWidth: 0.7)
        }
    }

    private func drawMesh(ctx: GraphicsContext, vertices: [Point3D], triangleIndices: [Int], center: CGPoint,
                          baseColor: (r: Double, g: Double, b: Double)) {
        guard vertices.count >= 3, triangleIndices.count >= 3 else { return }

        struct FaceTri { let a, b, c: Point3D; let nx, ny, nz: Double; let depth: Double }
        var faces: [FaceTri] = []
        var t = 0
        while t + 2 < triangleIndices.count {
            let a = vertices[triangleIndices[t]], b = vertices[triangleIndices[t + 1]], c = vertices[triangleIndices[t + 2]]
            let n = (b - a).cross(c - a).normalized
            let depth = (painterDepth(a) + painterDepth(b) + painterDepth(c)) / 3
            faces.append(FaceTri(a: a, b: b, c: c, nx: n.x, ny: n.y, nz: n.z, depth: depth))
            t += 3
        }

        let sorted = faces
            .filter { isFrontFacing(nx: $0.nx, ny: $0.ny, nz: $0.nz) }
            .sorted { $0.depth < $1.depth }

        for face in sorted {
            let br = lambert(nx: face.nx, ny: face.ny, nz: face.nz)
            let r = min(1.0, baseColor.r * br + 0.04)
            let g = min(1.0, baseColor.g * br + 0.04)
            let b = min(1.0, baseColor.b * br + 0.04)

            var path = Path()
            path.move(to: project(face.a, center: center))
            path.addLine(to: project(face.b, center: center))
            path.addLine(to: project(face.c, center: center))
            path.closeSubpath()

            ctx.fill(path, with: .color(Color(red: r, green: g, blue: b)))
        }
    }

    private func drawCylinder(ctx: GraphicsContext, worldCenter: Point3D, radius: Double,
                              height: Double, canvasCenter: CGPoint, baseColor: (r: Double, g: Double, b: Double)) {
        let n = 36
        let bz = worldCenter.z - height / 2   // bottom z
        let tz = worldCenter.z + height / 2   // top z
        let cr = baseColor.r, cg = baseColor.g, cb = baseColor.b

        // Side strips sorted back-to-front
        let angles = (0..<n).map { Double($0) / Double(n) * 2 * .pi }
        let sortedAngles = angles.sorted {
            let p0 = Point3D(x: worldCenter.x + cos($0)*radius, y: worldCenter.y + sin($0)*radius, z: worldCenter.z)
            let p1 = Point3D(x: worldCenter.x + cos($1)*radius, y: worldCenter.y + sin($1)*radius, z: worldCenter.z)
            return painterDepth(p0) < painterDepth(p1)
        }

        for a0 in sortedAngles {
            let a1 = a0 + 2 * .pi / Double(n)
            let midA = a0 + .pi / Double(n)
            let nx = cos(midA), ny = sin(midA)
            guard isFrontFacing(nx: nx, ny: ny, nz: 0) else { continue }

            let d   = max(0, nx * kLx + ny * kLy)
            let bri = kAmbient + (1.0 - kAmbient) * d

            var path = Path()
            path.move(to:    project(Point3D(x: worldCenter.x + radius*cos(a0), y: worldCenter.y + radius*sin(a0), z: bz), center: canvasCenter))
            path.addLine(to: project(Point3D(x: worldCenter.x + radius*cos(a1), y: worldCenter.y + radius*sin(a1), z: bz), center: canvasCenter))
            path.addLine(to: project(Point3D(x: worldCenter.x + radius*cos(a1), y: worldCenter.y + radius*sin(a1), z: tz), center: canvasCenter))
            path.addLine(to: project(Point3D(x: worldCenter.x + radius*cos(a0), y: worldCenter.y + radius*sin(a0), z: tz), center: canvasCenter))
            path.closeSubpath()

            ctx.fill(path, with: .color(Color(red: min(1, cr*bri+0.02), green: min(1, cg*bri+0.02), blue: min(1, cb*bri+0.02))))
        }

        // Caps: draw far cap first, near cap last
        let topCenter    = Point3D(x: worldCenter.x, y: worldCenter.y, z: tz)
        let bottomCenter = Point3D(x: worldCenter.x, y: worldCenter.y, z: bz)
        let topFirst = painterDepth(topCenter) < painterDepth(bottomCenter)

        let capOrder: [(Point3D, (Double, Double, Double))] = topFirst
            ? [(topCenter, (0, 0, 1)), (bottomCenter, (0, 0, -1))]
            : [(bottomCenter, (0, 0, -1)), (topCenter, (0, 0, 1))]

        for (capCenter, normal) in capOrder {
            guard isFrontFacing(nx: normal.0, ny: normal.1, nz: normal.2) else { continue }
            let bri = lambert(nx: normal.0, ny: normal.1, nz: normal.2)
            drawDisc(ctx: ctx, worldCenter: capCenter, worldRadius: radius, canvasCenter: canvasCenter,
                     br: cr * bri, bg: min(1, cg * bri), bb: min(1, cb * bri))
        }
    }

    private func drawCone(ctx: GraphicsContext, worldCenter: Point3D, radius: Double,
                          height: Double, canvasCenter: CGPoint, baseColor: (r: Double, g: Double, b: Double)) {
        let n = 36
        let baseZ = worldCenter.z
        let apexWorld = Point3D(x: worldCenter.x, y: worldCenter.y, z: worldCenter.z + height)
        let apexSc    = project(apexWorld, center: canvasCenter)
        let cr = baseColor.r, cg = baseColor.g, cb = baseColor.b
        let slopeLen = hypot(height, radius)

        let angles = (0..<n).map { Double($0) / Double(n) * 2 * .pi }
        let sorted = angles.sorted {
            let p0 = Point3D(x: worldCenter.x + cos($0)*radius, y: worldCenter.y + sin($0)*radius, z: baseZ)
            let p1 = Point3D(x: worldCenter.x + cos($1)*radius, y: worldCenter.y + sin($1)*radius, z: baseZ)
            return painterDepth(p0) < painterDepth(p1)
        }

        for a0 in sorted {
            let a1  = a0 + 2 * .pi / Double(n)
            let mid = a0 + .pi / Double(n)
            // Cone side normal: outward radial component + upward tilt
            let nx = cos(mid) * (height / slopeLen)
            let ny = sin(mid) * (height / slopeLen)
            let nz = radius / slopeLen
            guard isFrontFacing(nx: nx, ny: ny, nz: nz) else { continue }

            let bri = lambert(nx: nx, ny: ny, nz: nz)

            var path = Path()
            path.move(to:    project(Point3D(x: worldCenter.x + radius*cos(a0), y: worldCenter.y + radius*sin(a0), z: baseZ), center: canvasCenter))
            path.addLine(to: project(Point3D(x: worldCenter.x + radius*cos(a1), y: worldCenter.y + radius*sin(a1), z: baseZ), center: canvasCenter))
            path.addLine(to: apexSc)
            path.closeSubpath()

            ctx.fill(path, with: .color(Color(red: min(1, cr*bri+0.03), green: min(1, cg*bri), blue: min(1, cb*bri))))
        }

        // Base cap
        if isFrontFacing(nx: 0, ny: 0, nz: -1) {
            let bri = lambert(nx: 0, ny: 0, nz: -1)
            drawDisc(ctx: ctx, worldCenter: worldCenter, worldRadius: radius, canvasCenter: canvasCenter,
                     br: cr * bri, bg: cg * bri, bb: cb * bri)
        }
    }

    private func drawTorus(ctx: GraphicsContext, worldCenter: Point3D,
                           majorR: Double, minorR: Double, canvasCenter: CGPoint,
                           baseColor: (r: Double, g: Double, b: Double)) {
        let nMaj = 28   // segments around the ring
        let nMin = 14   // segments around the tube cross-section
        let tr = baseColor.r, tg = baseColor.g, tb = baseColor.b

        struct Patch { var path: Path; var r, g, b, depth: Double }
        var patches: [Patch] = []
        patches.reserveCapacity(nMaj * nMin)

        for i in 0..<nMaj {
            let phi0 = Double(i)   / Double(nMaj) * 2 * .pi
            let phi1 = Double(i+1) / Double(nMaj) * 2 * .pi

            for j in 0..<nMin {
                let theta0 = Double(j)   / Double(nMin) * 2 * .pi
                let theta1 = Double(j+1) / Double(nMin) * 2 * .pi

                func vert(phi: Double, theta: Double) -> Point3D {
                    Point3D(
                        x: worldCenter.x + (majorR + minorR * cos(theta)) * cos(phi),
                        y: worldCenter.y + (majorR + minorR * cos(theta)) * sin(phi),
                        z: worldCenter.z + minorR * sin(theta)
                    )
                }

                let midPhi   = (phi0   + phi1)   / 2
                let midTheta = (theta0 + theta1) / 2
                let nx = cos(midTheta) * cos(midPhi)
                let ny = cos(midTheta) * sin(midPhi)
                let nz = sin(midTheta)

                guard isFrontFacing(nx: nx, ny: ny, nz: nz) else { continue }
                let bri = lambert(nx: nx, ny: ny, nz: nz)

                var path = Path()
                path.move(to:    project(vert(phi: phi0, theta: theta0), center: canvasCenter))
                path.addLine(to: project(vert(phi: phi1, theta: theta0), center: canvasCenter))
                path.addLine(to: project(vert(phi: phi1, theta: theta1), center: canvasCenter))
                path.addLine(to: project(vert(phi: phi0, theta: theta1), center: canvasCenter))
                path.closeSubpath()

                let midPt = vert(phi: midPhi, theta: midTheta)
                patches.append(Patch(
                    path: path,
                    r: min(1, tr * bri + 0.02),
                    g: min(1, tg * bri + 0.02),
                    b: min(1, tb * bri + 0.02),
                    depth: painterDepth(midPt)
                ))
            }
        }

        patches.sort { $0.depth < $1.depth }
        for p in patches {
            ctx.fill(p.path, with: .color(Color(red: p.r, green: p.g, blue: p.b)))
        }
    }

    private func drawSurfaceStrip(ctx: GraphicsContext,
                                  curveA: [Point3D],
                                  curveB: [Point3D],
                                  center: CGPoint,
                                  baseColor: (r: Double, g: Double, b: Double)) {
        let count = min(curveA.count, curveB.count)
        guard count >= 2 else { return }

        struct Patch { let path: Path; let edge: Path; let depth: Double; let color: Color }
        var patches: [Patch] = []

        for index in 0..<(count - 1) {
            let a0 = curveA[index]
            let a1 = curveA[index + 1]
            let b1 = curveB[index + 1]
            let b0 = curveB[index]

            let u = a1 - a0
            let v = b0 - a0
            let nx = u.y * v.z - u.z * v.y
            let ny = u.z * v.x - u.x * v.z
            let nz = u.x * v.y - u.y * v.x

            let bri = lambert(nx: nx, ny: ny, nz: nz)
            let fill = Color(
                red: min(1, baseColor.r * bri + 0.03),
                green: min(1, baseColor.g * bri + 0.03),
                blue: min(1, baseColor.b * bri + 0.03)
            )

            let pts = [a0, a1, b1, b0].map { project($0, center: center) }
            var path = Path()
            path.move(to: pts[0])
            for point in pts.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()

            var edge = Path()
            edge.move(to: pts[0])
            for point in pts.dropFirst() { edge.addLine(to: point) }
            edge.closeSubpath()

            let depth = [a0, a1, b0, b1].reduce(0.0) { $0 + painterDepth($1) } / 4
            patches.append(Patch(path: path, edge: edge, depth: depth, color: fill))
        }

        patches.sort { $0.depth < $1.depth }
        for patch in patches {
            ctx.fill(patch.path, with: .color(patch.color.opacity(0.94)))
            ctx.stroke(patch.edge,
                       with: .color(Color(red: baseColor.r * 0.55, green: baseColor.g * 0.55, blue: baseColor.b * 0.55, opacity: 0.85)),
                       lineWidth: 0.8)
        }

        draw(ctx: ctx, shape: .polyline(curveA), center: center, tint: baseColor)
        draw(ctx: ctx, shape: .polyline(curveB), center: center, tint: baseColor)
    }

    // MARK: - Helpers

    private func renderedColor(from shape: GeometricShape,
                               fallback: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        guard case .painted(_, let material) = shape else { return fallback }
        return (material.r, material.g, material.b)
    }

    private func drawDot(ctx: GraphicsContext, at pt: CGPoint, color: Color, r: CGFloat) {
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r, y: pt.y-r, width: r*2, height: r*2)),
                 with: .color(color))
    }

    // MARK: - SVG Export

    private func exportSVG() {
        let svg = SVGExporter.export(shapes: modeShapes)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "geometry.svg"
        panel.canCreateDirectories = true
        panel.title = "Export SVG"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Failed to export SVG"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - 3D Export

    private func export3D(_ format: Export3DFormat) {
        let scene = ExportSceneBuilder.build(from: modeShapes)
        guard !scene.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "geometry.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.title = "Export \(format.menuTitle)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .obj:
                let out = OBJExporter.export(scene: scene, mtlFileName: url.deletingPathExtension().lastPathComponent + ".mtl")
                try out.obj.write(to: url, atomically: true, encoding: .utf8)
                let mtlURL = url.deletingPathExtension().appendingPathExtension("mtl")
                try out.mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
            case .stl:
                try STLExporter.export(scene: scene).write(to: url)
            case .ply:
                try PLYExporter.export(scene: scene).write(to: url)
            case .gltf:
                try GLTFExporter.exportGLB(scene: scene).write(to: url)
            case .collada:
                try ColladaExporter.export(scene: scene).write(to: url, atomically: true, encoding: .utf8)
            case .fbx:
                try FBXExporter.export(scene: scene).write(to: url, atomically: true, encoding: .utf8)
            case .usda:
                try USDExporter.exportUSDA(scene: scene).write(to: url, atomically: true, encoding: .utf8)
            case .usdz:
                let assetName = url.deletingPathExtension().lastPathComponent
                try USDExporter.exportUSDZ(scene: scene, assetName: assetName).write(to: url)
            case .step:
                try STEPExporter.export(scene: scene, name: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
            case .iges:
                try IGESExporter.export(scene: scene, fileName: url.lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
            case .threeMF:
                try ThreeMFExporter.export(scene: scene).write(to: url)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Failed to export \(format.menuTitle)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func drawEmptyState(ctx: GraphicsContext, size: CGSize) {
        let message = viewMode == .twoD
            ? "No geometry — add a 2D Shapes node"
            : "No geometry — add a Geometry node"
        ctx.draw(
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.2)),
            at: CGPoint(x: size.width / 2, y: size.height / 2)
        )
    }
}
