import SwiftUI

struct GeometryPreviewView: View {
    @EnvironmentObject var graph: NodeGraph

    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var zoom: CGFloat = 30       // pixels per world unit
    @State private var lastZoom: CGFloat = 30
    @State private var viewMode: ViewMode = .perspective

    // World-space light direction (normalized): upper-right-front
    // L = normalize(0.5, 0.3, 1.0)
    private let kLx = 0.4303, kLy = 0.2582, kLz = 0.8607
    private let kAmbient: Double = 0.15

    enum ViewMode: String, CaseIterable {
        case top         = "Top (XY)"
        case front       = "Front (XZ)"
        case right       = "Right (YZ)"
        case perspective = "Perspective"
        case realistic   = "Realistic"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { _ in
                if viewMode == .realistic {
                    FilamentRenderView(shapes: graph.previewShapes)
                } else {
                    Canvas { ctx, size in
                        let center = CGPoint(
                            x: size.width  / 2 + pan.width,
                            y: size.height / 2 + pan.height
                        )
                        drawBackground(ctx: ctx, size: size)
                        drawGrid(ctx: ctx, size: size, center: center)
                        drawAxes(ctx: ctx, size: size, center: center)
                        for shape in graph.previewShapes {
                            draw(ctx: ctx, shape: shape, center: center)
                        }
                        if graph.previewShapes.isEmpty {
                            drawEmptyState(ctx: ctx, size: size)
                        }
                    }
                    .gesture(panGesture)
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
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)
            Spacer()
            if viewMode != .realistic {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        pan = .zero; panAnchor = .zero
                        zoom = 30; lastZoom = 30
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
                .fill(graph.previewShapes.isEmpty ? Color.red : Color.green)
                .frame(width: 6, height: 6)
            Text(graph.previewShapes.isEmpty
                 ? "No geometry — add a geometry node"
                 : "\(graph.previewShapes.count) object\(graph.previewShapes.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(viewMode.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Divider().frame(height: 10)
            if viewMode == .realistic {
                Text("Drag to orbit  ·  Pinch / scroll to zoom  ·  ⌘-drag to pan")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
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

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                pan = CGSize(width:  panAnchor.width  + v.translation.width,
                             height: panAnchor.height + v.translation.height)
            }
            .onEnded { _ in panAnchor = pan }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in zoom = max(4, min(600, lastZoom * v)) }
            .onEnded   { _ in lastZoom = zoom }
    }

    // MARK: - Projection

    private func project(_ p: Point3D, center: CGPoint) -> CGPoint {
        switch viewMode {
        case .top:
            return CGPoint(x: center.x + p.x * zoom, y: center.y - p.y * zoom)
        case .front:
            return CGPoint(x: center.x + p.x * zoom, y: center.y - p.z * zoom)
        case .right:
            return CGPoint(x: center.x + p.y * zoom, y: center.y - p.z * zoom)
        case .perspective, .realistic:
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
        case .top:                   dot =  nz
        case .front:                 dot =  ny
        case .right:                 dot =  nx
        case .perspective, .realistic: dot =  nx + ny + nz
        }
        return dot > -0.01
    }

    /// Depth value for painter's algorithm — smaller = farther = drawn first
    private func painterDepth(_ p: Point3D) -> Double {
        switch viewMode {
        case .top:                   return  p.z
        case .front:                 return  p.y
        case .right:                 return  p.x
        case .perspective, .realistic: return  p.x + p.y + p.z
        }
    }

    /// Screen-space unit vector pointing toward the light source
    private func screenLightDir() -> CGPoint {
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
            case .top:
                hStart = Point3D(x: -lim, y: coord, z: 0);  hEnd = Point3D(x: lim, y: coord, z: 0)
                vStart = Point3D(x: coord, y: -lim, z: 0);  vEnd = Point3D(x: coord, y: lim, z: 0)
            case .front:
                hStart = Point3D(x: -lim, y: 0, z: coord);  hEnd = Point3D(x: lim, y: 0, z: coord)
                vStart = Point3D(x: coord, y: 0, z: -lim);  vEnd = Point3D(x: coord, y: 0, z: lim)
            case .right:
                hStart = Point3D(x: 0, y: -lim, z: coord);  hEnd = Point3D(x: 0, y: lim, z: coord)
                vStart = Point3D(x: 0, y: coord, z: -lim);  vEnd = Point3D(x: 0, y: coord, z: lim)
            case .perspective, .realistic:
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
        let len = Double(max(size.width, size.height)) / zoom * 0.35
        struct Axis { let end: Point3D; let color: Color; let label: String }

        let axes: [Axis]
        switch viewMode {
        case .top:
            axes = [Axis(end: Point3D(x: len, y: 0, z: 0), color: .red,   label: "X"),
                    Axis(end: Point3D(x: 0, y: len, z: 0), color: .green, label: "Y")]
        case .front:
            axes = [Axis(end: Point3D(x: len, y: 0, z: 0), color: .red,  label: "X"),
                    Axis(end: Point3D(x: 0, y: 0, z: len), color: .blue, label: "Z")]
        case .right:
            axes = [Axis(end: Point3D(x: 0, y: len, z: 0), color: .green, label: "Y"),
                    Axis(end: Point3D(x: 0, y: 0, z: len), color: .blue,  label: "Z")]
        case .perspective, .realistic:
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

        case .label(let text, let p):
            let sp = project(p, center: center)
            ctx.draw(
                Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.75)),
                at: CGPoint(x: sp.x, y: sp.y - 10)
            )

        case .painted(let inner, let material):
            draw(ctx: ctx, shape: inner, center: center, tint: (material.r, material.g, material.b))
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

    private func drawEmptyState(ctx: GraphicsContext, size: CGSize) {
        ctx.draw(
            Text("No geometry — add a Geometry node")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.2)),
            at: CGPoint(x: size.width / 2, y: size.height / 2)
        )
    }
}
