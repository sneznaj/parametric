import Foundation

// MARK: - Vector math helpers shared by the mesh/CSG/curve kernels

extension Point3D {
    var length: Double { sqrt(x * x + y * y + z * z) }

    var normalized: Point3D {
        let l = length
        guard l > 1e-12 else { return .zero }
        return Point3D(x: x / l, y: y / l, z: z / l)
    }

    func dot(_ o: Point3D) -> Double { x * o.x + y * o.y + z * o.z }

    func cross(_ o: Point3D) -> Point3D {
        Point3D(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
    }
}

/// Tessellation and mesh-construction kernel. Builds triangle-soup meshes
/// (`vertices` + flat `triangleIndices`, stride 3, CCW-outward winding) for
/// everything that can't be expressed as one of the app's analytic
/// `GeometricShape` primitives — extrusions, revolves, sweeps, pipes, and
/// mesh-level operations (cap/offset/bounding box/volume/centroid) used by
/// the Surface and Solid node categories. Not a NURBS/B-rep kernel — meshes
/// are approximate, but adequate for the shapes this app can express.
enum MeshKernel {
    typealias MeshData = (vertices: [Point3D], triangleIndices: [Int])

    static func merge(_ a: MeshData, _ b: MeshData) -> MeshData {
        guard !a.vertices.isEmpty else { return b }
        guard !b.vertices.isEmpty else { return a }
        let offset = a.vertices.count
        return (a.vertices + b.vertices, a.triangleIndices + b.triangleIndices.map { $0 + offset })
    }

    /// Fan-triangulates a closed point loop from its centroid. `flipped`
    /// reverses winding; a loop that is CCW as seen from +Z produces a
    /// +Z-facing cap when `flipped == false`.
    static func fanCap(loop: [Point3D], flipped: Bool) -> MeshData {
        guard loop.count >= 3 else { return ([], []) }
        let centroid = loop.reduce(Point3D.zero, +).scaled(by: 1.0 / Double(loop.count))
        var verts = loop
        verts.append(centroid)
        let c = loop.count
        var idx: [Int] = []
        idx.reserveCapacity(loop.count * 3)
        for i in 0..<loop.count {
            let i2 = (i + 1) % loop.count
            idx.append(contentsOf: flipped ? [c, i2, i] : [c, i, i2])
        }
        return (verts, idx)
    }

    /// Stitches a sequence of equal-count point rings into a tube of quads
    /// (each split into 2 outward-wound triangles). `closeLoop` also
    /// connects the last ring back to the first (e.g. a 360° revolve).
    static func stitchRings(_ rings: [[Point3D]], closeLoop: Bool) -> MeshData {
        guard rings.count >= 2, let n = rings.first?.count, n >= 2 else { return ([], []) }
        var verts: [Point3D] = []
        verts.reserveCapacity(rings.count * n)
        for ring in rings { verts.append(contentsOf: ring) }

        var idx: [Int] = []
        let segCount = closeLoop ? rings.count : rings.count - 1
        for s in 0..<segCount {
            let r0 = s
            let r1 = (s + 1) % rings.count
            let base0 = r0 * n, base1 = r1 * n
            for i in 0..<n {
                let i2 = (i + 1) % n
                let ti = base1 + i, ti2 = base1 + i2
                let bi = base0 + i, bi2 = base0 + i2
                idx.append(contentsOf: [ti, bi, ti2])
                idx.append(contentsOf: [ti2, bi, bi2])
            }
        }
        return (verts, idx)
    }

    /// Builds a triangle-mesh grid from `rows[v][u]` (all rows equal length),
    /// `v` running along the loft direction and `u` along each cross-section.
    /// Unlike `stitchRings` (which always wraps within a ring), `closeV` and
    /// `closeU` wrap their own direction independently, so an open-profile
    /// loft doesn't get a spurious closing quad back to its own start point.
    static func gridMesh(rows: [[Point3D]], closeV: Bool, closeU: Bool) -> MeshData {
        guard rows.count >= 2, let n = rows.first?.count, n >= 2,
              rows.allSatisfy({ $0.count == n }) else { return ([], []) }
        var verts: [Point3D] = []
        verts.reserveCapacity(rows.count * n)
        for row in rows { verts.append(contentsOf: row) }

        var idx: [Int] = []
        let vSegs = closeV ? rows.count : rows.count - 1
        let uSegs = closeU ? n : n - 1
        for v in 0..<vSegs {
            let r0 = v, r1 = (v + 1) % rows.count
            let base0 = r0 * n, base1 = r1 * n
            for u in 0..<uSegs {
                let u2 = (u + 1) % n
                let ti = base1 + u, ti2 = base1 + u2
                let bi = base0 + u, bi2 = base0 + u2
                idx.append(contentsOf: [ti, bi, ti2])
                idx.append(contentsOf: [ti2, bi, bi2])
            }
        }
        return (verts, idx)
    }

    /// Builds a smooth loft through N already-resampled, equal-length
    /// cross-section rows (`sections[i]` = curve `i`'s `columnCount` points,
    /// in curve order — 2+ sections). Each column across sections (constant
    /// arc-length position along every curve) is fit with a global B-spline
    /// interpolation (`CurveKernel.interpolatedSpline`) and re-sampled, so
    /// with 3+ sections the surface curves smoothly *between* curves too
    /// (Grasshopper's default "Normal" loft) instead of the straight-line
    /// ruled interpolation a 2-curve loft is limited to (a 2-point fit is
    /// inherently linear, so that case still degenerates to the old
    /// behavior). `closeV` wraps the last section back to the first
    /// (Grasshopper's "Closed" loft toggle); `closeU` wraps each row and is
    /// meant for when the lofted curves are themselves closed profiles.
    static func loftSurface(sections: [[Point3D]], closeV: Bool, closeU: Bool, samplesPerSpan: Int = 10) -> MeshData {
        guard sections.count >= 2, let columnCount = sections.first?.count, columnCount >= 2,
              sections.allSatisfy({ $0.count == columnCount }) else { return ([], []) }

        var columns: [[Point3D]] = []
        for u in 0..<columnCount {
            let columnPoints = sections.map { $0[u] }
            let (controlPoints, degree) = CurveKernel.interpolatedSpline(through: columnPoints, degree: 3, closed: closeV)
            var sampled = CurveKernel.sampleSpline(controlPoints: controlPoints, degree: degree, closed: closeV, samplesPerSpan: samplesPerSpan)
            // A closed spline's sample wraps its last point back onto its
            // first (see CurveKernel.sampleClosedSpline) — drop the
            // duplicate so gridMesh's own closeV wrap doesn't double it up.
            if closeV, sampled.count > 1, (sampled.first! - sampled.last!).length < 1e-9 {
                sampled.removeLast()
            }
            columns.append(sampled)
        }
        guard let vCount = columns.first?.count, vCount >= 2, columns.allSatisfy({ $0.count == vCount }) else {
            return ([], [])
        }
        let rows: [[Point3D]] = (0..<vCount).map { v in columns.map { $0[v] } }
        return gridMesh(rows: rows, closeV: closeV, closeU: closeU)
    }

    // MARK: - Primitive tessellation (used to feed CSG boolean ops)

    static func box(min: Point3D, max: Point3D) -> MeshData {
        let faces: [(Point3D, Point3D, Point3D, Point3D)] = [
            (Point3D(x: max.x, y: min.y, z: max.z), Point3D(x: max.x, y: max.y, z: max.z),
             Point3D(x: max.x, y: max.y, z: min.z), Point3D(x: max.x, y: min.y, z: min.z)),
            (Point3D(x: min.x, y: min.y, z: min.z), Point3D(x: min.x, y: max.y, z: min.z),
             Point3D(x: min.x, y: max.y, z: max.z), Point3D(x: min.x, y: min.y, z: max.z)),
            (Point3D(x: min.x, y: max.y, z: max.z), Point3D(x: max.x, y: max.y, z: max.z),
             Point3D(x: max.x, y: max.y, z: min.z), Point3D(x: min.x, y: max.y, z: min.z)),
            (Point3D(x: min.x, y: min.y, z: min.z), Point3D(x: max.x, y: min.y, z: min.z),
             Point3D(x: max.x, y: min.y, z: max.z), Point3D(x: min.x, y: min.y, z: max.z)),
            (Point3D(x: max.x, y: min.y, z: max.z), Point3D(x: max.x, y: max.y, z: max.z),
             Point3D(x: min.x, y: max.y, z: max.z), Point3D(x: min.x, y: min.y, z: max.z)),
            (Point3D(x: min.x, y: min.y, z: min.z), Point3D(x: min.x, y: max.y, z: min.z),
             Point3D(x: max.x, y: max.y, z: min.z), Point3D(x: max.x, y: min.y, z: min.z)),
        ]
        var verts: [Point3D] = []
        var idx: [Int] = []
        for (a, b, c, d) in faces {
            let base = verts.count
            verts.append(contentsOf: [a, b, c, d])
            // Keep the triangles CCW when viewed from outside the box.  The
            // renderer uses back-face culling, so inward winding makes faces
            // disappear as the camera orbits around the object.
            idx.append(contentsOf: [base, base + 2, base + 1, base, base + 3, base + 2])
        }
        return (verts, idx)
    }

    static func sphere(center: Point3D, radius: Double, segments: Int = 64, rings: Int = 32) -> MeshData {
        let segs = max(8, segments), r = max(4, rings)
        var verts: [Point3D] = []
        for j in 0...r {
            let phi = Double.pi * Double(j) / Double(r)
            let z = cos(phi), rr = sin(phi)
            for i in 0...segs {
                let theta = 2 * Double.pi * Double(i) / Double(segs)
                verts.append(center + Point3D(x: rr * cos(theta), y: rr * sin(theta), z: z).scaled(by: radius))
            }
        }
        let cols = segs + 1
        var idx: [Int] = []
        for j in 0..<r {
            for i in 0..<segs {
                let a = j * cols + i, b = a + 1
                let c = (j + 1) * cols + i, d = c + 1
                idx.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return (verts, idx)
    }

    static func cylinder(center: Point3D, radius: Double, height: Double, segments: Int = 32) -> MeshData {
        let segs = max(8, segments)
        let hh = height * 0.5
        var top: [Point3D] = [], bot: [Point3D] = []
        for i in 0..<segs {
            let a = 2 * Double.pi * Double(i) / Double(segs)
            let x = radius * cos(a), y = radius * sin(a)
            top.append(center + Point3D(x: x, y: y, z: hh))
            bot.append(center + Point3D(x: x, y: y, z: -hh))
        }
        var mesh = stitchRings([bot, top], closeLoop: false)
        mesh = merge(mesh, fanCap(loop: bot, flipped: true))
        mesh = merge(mesh, fanCap(loop: top, flipped: false))
        return mesh
    }

    static func cone(center: Point3D, radius: Double, height: Double, segments: Int = 32) -> MeshData {
        let segs = max(8, segments)
        let hh = height * 0.5
        var base: [Point3D] = []
        for i in 0..<segs {
            let a = 2 * Double.pi * Double(i) / Double(segs)
            base.append(center + Point3D(x: radius * cos(a), y: radius * sin(a), z: -hh))
        }
        let apex = center + Point3D(x: 0, y: 0, z: hh)
        var mesh = extrudeToPoint(profile: base, apex: apex, capped: false)
        mesh = merge(mesh, fanCap(loop: base, flipped: true))
        return mesh
    }

    static func torus(center: Point3D, majorRadius: Double, minorRadius: Double,
                       majorSegments: Int = 32, minorSegments: Int = 16) -> MeshData {
        let majSeg = max(12, majorSegments), minSeg = max(6, minorSegments)
        var rings: [[Point3D]] = []
        for i in 0...majSeg {
            let theta = 2 * Double.pi * Double(i) / Double(majSeg)
            let ringCenter = center + Point3D(x: cos(theta), y: sin(theta), z: 0).scaled(by: majorRadius)
            var ring: [Point3D] = []
            for j in 0..<minSeg {
                let phi = 2 * Double.pi * Double(j) / Double(minSeg)
                let radial = Point3D(x: cos(theta) * cos(phi), y: sin(theta) * cos(phi), z: sin(phi))
                ring.append(ringCenter + radial.scaled(by: minorRadius))
            }
            rings.append(ring)
        }
        return stitchRings(Array(rings.dropLast()), closeLoop: true)
    }

    // MARK: - Curve-driven construction

    static func extrude(profile: [Point3D], direction: Point3D, capped: Bool) -> MeshData {
        guard profile.count >= 3 else { return ([], []) }
        let shifted = profile.map { $0 + direction }
        var mesh = stitchRings([profile, shifted], closeLoop: false)
        if capped {
            mesh = merge(mesh, fanCap(loop: profile, flipped: true))
            mesh = merge(mesh, fanCap(loop: shifted, flipped: false))
        }
        return mesh
    }

    static func extrudeToPoint(profile: [Point3D], apex: Point3D, capped: Bool) -> MeshData {
        guard profile.count >= 3 else { return ([], []) }
        var verts = profile
        verts.append(apex)
        let apexIdx = profile.count
        var idx: [Int] = []
        for i in 0..<profile.count {
            let i2 = (i + 1) % profile.count
            idx.append(contentsOf: [apexIdx, i, i2])
        }
        var mesh: MeshData = (verts, idx)
        if capped {
            mesh = merge(mesh, fanCap(loop: profile, flipped: true))
        }
        return mesh
    }

    static func revolve(profile: [Point3D], axisOrigin: Point3D, axisDir: Point3D,
                         angleDegrees: Double, segments: Int) -> MeshData {
        let axis = axisDir.normalized
        guard axis.length > 1e-9, profile.count >= 2 else { return ([], []) }
        let segs = max(3, segments)
        let totalRad = angleDegrees * .pi / 180
        var rings: [[Point3D]] = []
        for s in 0...segs {
            let t = Double(s) / Double(segs)
            let ring = profile.map { pt -> Point3D in
                let rel = pt - axisOrigin
                return axisOrigin + rel.rotated(angle: t * totalRad, axis: axis)
            }
            rings.append(ring)
        }
        let closeLoop = abs(angleDegrees.truncatingRemainder(dividingBy: 360)) < 1e-6 && angleDegrees != 0
        var mesh = stitchRings(closeLoop ? Array(rings.dropLast()) : rings, closeLoop: closeLoop)
        if !closeLoop && profile.count >= 3 {
            mesh = merge(mesh, fanCap(loop: rings.first!, flipped: true))
            mesh = merge(mesh, fanCap(loop: rings.last!, flipped: false))
        }
        return mesh
    }

    /// Sweeps a local-space profile (expected centered near the origin, in
    /// its own XY plane) along a rail using rotation-minimizing frames.
    private static func sweepRings(profile: [Point3D], rail: [Point3D]) -> [[Point3D]] {
        guard rail.count >= 2, profile.count >= 3 else { return [] }
        var tangents: [Point3D] = []
        for i in 0..<rail.count {
            if i == 0 { tangents.append((rail[1] - rail[0]).normalized) }
            else if i == rail.count - 1 { tangents.append((rail[i] - rail[i - 1]).normalized) }
            else { tangents.append((rail[i + 1] - rail[i - 1]).normalized) }
        }

        var normal = orthogonal(to: tangents[0])
        var rings: [[Point3D]] = []
        var prevTangent = tangents[0]
        for i in 0..<rail.count {
            let t = tangents[i]
            if i > 0 { normal = parallelTransport(normal, from: prevTangent, to: t) }
            let binormal = t.cross(normal).normalized
            let ring = profile.map { pt in rail[i] + normal.scaled(by: pt.x) + binormal.scaled(by: pt.y) }
            rings.append(ring)
            prevTangent = t
        }
        return rings
    }

    static func sweep1(profile: [Point3D], rail: [Point3D], capped: Bool = false) -> MeshData {
        let rings = sweepRings(profile: profile, rail: rail)
        guard rings.count >= 2 else { return ([], []) }
        var mesh = stitchRings(rings, closeLoop: false)
        if capped {
            mesh = merge(mesh, fanCap(loop: rings.first!, flipped: true))
            mesh = merge(mesh, fanCap(loop: rings.last!, flipped: false))
        }
        return mesh
    }

    static func pipe(rail: [Point3D], radius: Double, segments: Int, capped: Bool) -> MeshData {
        let segs = max(6, segments)
        var profile: [Point3D] = []
        for i in 0..<segs {
            let a = 2 * Double.pi * Double(i) / Double(segs)
            profile.append(Point3D(x: radius * cos(a), y: radius * sin(a), z: 0))
        }
        return sweep1(profile: profile, rail: rail, capped: capped)
    }

    static func boundarySurface(profile: [Point3D]) -> MeshData {
        fanCap(loop: profile, flipped: false)
    }

    private static func orthogonal(to v: Point3D) -> Point3D {
        let helper = abs(v.x) < 0.9 ? Point3D(x: 1, y: 0, z: 0) : Point3D(x: 0, y: 1, z: 0)
        return v.cross(helper).normalized
    }

    private static func parallelTransport(_ vector: Point3D, from t0: Point3D, to t1: Point3D) -> Point3D {
        let axis = t0.cross(t1)
        let axisLen = axis.length
        guard axisLen > 1e-9 else { return vector }
        let angle = atan2(axisLen, t0.dot(t1))
        return vector.rotated(angle: angle, axis: axis.scaled(by: 1.0 / axisLen))
    }

    // MARK: - Mesh operations

    /// Fills naked (boundary) edge loops with a fan cap. Boundary edges are
    /// those touched by exactly one triangle.
    static func capHoles(_ mesh: MeshData) -> MeshData {
        let tris = mesh.triangleIndices
        guard tris.count >= 3 else { return mesh }

        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) * 1_000_000 + Int64(max(a, b)) }

        var edgeCount: [Int64: Int] = [:]
        var t = 0
        while t + 2 < tris.count {
            let a = tris[t], b = tris[t + 1], c = tris[t + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] { edgeCount[key(u, v), default: 0] += 1 }
            t += 3
        }

        var boundaryNext: [Int: Int] = [:]
        t = 0
        while t + 2 < tris.count {
            let a = tris[t], b = tris[t + 1], c = tris[t + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] where edgeCount[key(u, v)] == 1 {
                boundaryNext[u] = v
            }
            t += 3
        }

        var visited = Set<Int>()
        var result = mesh
        for start in boundaryNext.keys where !visited.contains(start) {
            var loopIdx: [Int] = [start]
            visited.insert(start)
            var cur = start
            while let nxt = boundaryNext[cur], nxt != start, !visited.contains(nxt) {
                loopIdx.append(nxt)
                visited.insert(nxt)
                cur = nxt
            }
            if loopIdx.count >= 3 {
                result = merge(result, fanCap(loop: loopIdx.map { mesh.vertices[$0] }, flipped: false))
            }
        }
        return result
    }

    /// Per-vertex smooth normals for a tessellated shape, using an analytic
    /// formula where one exists instead of face-normal averaging.
    ///
    /// `sphere(...)` duplicates its seam column (theta = 0 and theta = 2*pi)
    /// so the UV wrap has somewhere to split, and duplicates every vertex in
    /// the pole rings (rr = 0, so every column collapses to the same point).
    /// Averaged face normals give those duplicate-position vertices only
    /// half the adjacent-triangle fan each (the other half lands on their
    /// twin, which is a different vertex index at the same position), which
    /// biases their normals a degree or two apart and shows up as a visible
    /// shading seam running pole-to-pole under specular lighting. A sphere's
    /// normal is just the radial direction, so compute that directly instead.
    static func vertexNormals(for geometry: GeometricShape, mesh: MeshData) -> [Point3D] {
        if case .sphere(let center, _) = geometry {
            return mesh.vertices.map { ($0 - center).normalized }
        }
        return vertexNormals(mesh)
    }

    /// Per-vertex smooth normals, averaged from adjacent face normals.
    static func vertexNormals(_ mesh: MeshData) -> [Point3D] {
        var acc = [Point3D](repeating: .zero, count: mesh.vertices.count)
        let tris = mesh.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let ia = tris[t], ib = tris[t + 1], ic = tris[t + 2]
            let a = mesh.vertices[ia], b = mesh.vertices[ib], c = mesh.vertices[ic]
            let n = (b - a).cross(c - a)
            acc[ia] = acc[ia] + n
            acc[ib] = acc[ib] + n
            acc[ic] = acc[ic] + n
            t += 3
        }
        return acc.map { $0.length > 1e-12 ? $0.normalized : .zero }
    }

    static func offset(_ mesh: MeshData, distance: Double) -> MeshData {
        let normals = vertexNormals(mesh)
        let newVerts = zip(mesh.vertices, normals).map { p, n in p + n.scaled(by: distance) }
        return (newVerts, mesh.triangleIndices)
    }

    static func boundingBox(of shapes: [GeometricShape]) -> (min: Point3D, max: Point3D)? {
        var lo = Point3D(x: .infinity, y: .infinity, z: .infinity)
        var hi = Point3D(x: -.infinity, y: -.infinity, z: -.infinity)
        var any = false
        func expand(_ p: Point3D) {
            any = true
            lo = Point3D(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
            hi = Point3D(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
        }
        func visit(_ s: GeometricShape) {
            switch s {
            case .point(let p): expand(p)
            case .line(let a, let b): expand(a); expand(b)
            case .polyline(let pts), .polygon(let pts): pts.forEach(expand)
            case .surfaceStrip(let a, let b): a.forEach(expand); b.forEach(expand)
            case .circle(let c, let r):
                expand(Point3D(x: c.x - r, y: c.y - r, z: c.z)); expand(Point3D(x: c.x + r, y: c.y + r, z: c.z))
            case .sphere(let c, let r):
                expand(c - Point3D(x: r, y: r, z: r)); expand(c + Point3D(x: r, y: r, z: r))
            case .box(let a, let b): expand(a); expand(b)
            case .cylinder(let c, let r, let h):
                expand(Point3D(x: c.x - r, y: c.y - r, z: c.z - h/2)); expand(Point3D(x: c.x + r, y: c.y + r, z: c.z + h/2))
            case .cone(let c, let r, let h):
                expand(Point3D(x: c.x - r, y: c.y - r, z: c.z - h/2)); expand(Point3D(x: c.x + r, y: c.y + r, z: c.z + h/2))
            case .torus(let c, let maj, let minR):
                let rr = maj + minR
                expand(Point3D(x: c.x - rr, y: c.y - rr, z: c.z - minR)); expand(Point3D(x: c.x + rr, y: c.y + rr, z: c.z + minR))
            case .mesh(let verts, _): verts.forEach(expand)
            case .spline(let cps, let degree, let closed):
                CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed).forEach(expand)
            case .label(_, let p): expand(p)
            case .styled2D(let inner, _): visit(inner)
            case .painted(let inner, _): visit(inner)
            }
        }
        shapes.forEach(visit)
        return any ? (lo, hi) : nil
    }

    static func volume(of mesh: MeshData) -> Double {
        var vol = 0.0
        let tris = mesh.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let a = mesh.vertices[tris[t]], b = mesh.vertices[tris[t + 1]], c = mesh.vertices[tris[t + 2]]
            vol += a.dot(b.cross(c))
            t += 3
        }
        return abs(vol) / 6.0
    }

    static func centroid(of mesh: MeshData) -> Point3D {
        var totalVol6 = 0.0
        var weighted = Point3D.zero
        let tris = mesh.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let a = mesh.vertices[tris[t]], b = mesh.vertices[tris[t + 1]], c = mesh.vertices[tris[t + 2]]
            let vol6 = a.dot(b.cross(c))
            let tetraCentroid = (a + b + c).scaled(by: 0.25)
            weighted = weighted + tetraCentroid.scaled(by: vol6)
            totalVol6 += vol6
            t += 3
        }
        guard abs(totalVol6) > 1e-12 else {
            guard !mesh.vertices.isEmpty else { return .zero }
            return mesh.vertices.reduce(Point3D.zero, +).scaled(by: 1.0 / Double(mesh.vertices.count))
        }
        return weighted.scaled(by: 1.0 / totalVol6)
    }

    /// Extracts (or tessellates) mesh data from any renderable `GeometricShape`.
    static func meshData(from shape: GeometricShape) -> MeshData? {
        switch shape {
        case .mesh(let v, let t): return (v, t)
        case .box(let mn, let mx): return box(min: mn, max: mx)
        case .sphere(let c, let r): return sphere(center: c, radius: r)
        case .cylinder(let c, let r, let h): return cylinder(center: c, radius: r, height: h)
        case .cone(let c, let r, let h): return cone(center: c, radius: r, height: h)
        case .torus(let c, let maj, let minR): return torus(center: c, majorRadius: maj, minorRadius: minR)
        case .painted(let inner, _): return meshData(from: inner)
        case .styled2D(let inner, _): return meshData(from: inner)
        default: return nil
        }
    }
}
