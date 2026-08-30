import Foundation

/// Curve utilities shared by the Curve-category nodes and by
/// `NodeEvaluator`'s existing loft/blend-arc cases. Every curve-analysis op
/// (Offset/Fillet/Divide/Length/...) works on a flattened polyline
/// approximation pulled from a `GeometricShape` via `polylinePoints` —
/// `.line`, `.polyline`, `.polygon`, `.circle` are already point lists, and
/// `.spline` (a real non-rational B-spline: control points + degree,
/// optionally closed) is evaluated down to one via De Boor's algorithm — so
/// those ops stay geometric approximations rather than exact curve-on-curve
/// math even for spline input. Spline construction itself (`sampleSpline`,
/// `interpolatedSpline`) is exact NURBS-style math; see the "B-spline
/// evaluation" and "Global curve interpolation" sections below.
enum CurveKernel {

    // MARK: - Extraction

    static func firstCurve(from value: PortValue?) -> GeometricShape? {
        guard case .geometry(let shapes) = value else { return nil }
        for shape in shapes {
            if let curve = curveShape(from: shape) { return curve }
        }
        return nil
    }

    /// Every curve-like shape in a `.geometry` value, in order — the loft's
    /// "Curves" input takes a list of section curves rather than a single one.
    static func allCurves(from value: PortValue?) -> [GeometricShape] {
        guard case .geometry(let shapes) = value else { return [] }
        return shapes.compactMap { curveShape(from: $0) }
    }

    static func curveShape(from shape: GeometricShape) -> GeometricShape? {
        switch shape {
        case .line, .polyline, .polygon, .circle, .spline:
            return shape
        case .painted(let inner, _):
            return curveShape(from: inner)
        case .styled2D(let inner, _):
            return curveShape(from: inner)
        default:
            return nil
        }
    }

    /// Flattens any curve-like shape to an ordered point list. For `.spline`
    /// this evaluates the B-spline via `sampleSpline` rather than returning
    /// the control polygon.
    static func polylinePoints(for shape: GeometricShape) -> [Point3D] {
        switch shape {
        case .line(let a, let b):
            return [a, b]
        case .polyline(let points):
            return points
        case .polygon(let points):
            guard let first = points.first else { return [] }
            return points + [first]
        case .circle(let center, let radius):
            let segments = 64
            return (0...segments).map { index in
                let angle = Double(index) / Double(segments) * 2 * .pi
                return Point3D(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle), z: center.z)
            }
        case .spline(let controlPoints, let degree, let closed):
            return sampleSpline(controlPoints: controlPoints, degree: degree, closed: closed)
        case .painted(let inner, _):
            return polylinePoints(for: inner)
        case .styled2D(let inner, _):
            return polylinePoints(for: inner)
        default:
            return []
        }
    }

    /// Control points of the curve: a spline's actual control polygon, or
    /// (for every other curve type, which is effectively degree-1) its
    /// vertex list — mirrors Grasshopper's "Control Points" behavior on a
    /// polyline/line.
    static func controlPoints(for shape: GeometricShape) -> [Point3D] {
        switch shape {
        case .spline(let controlPoints, _, _):
            return controlPoints
        case .painted(let inner, _):
            return controlPoints(for: inner)
        case .styled2D(let inner, _):
            return controlPoints(for: inner)
        default:
            return polylinePoints(for: shape)
        }
    }

    // MARK: - B-spline evaluation (non-rational, De Boor's algorithm)
    //
    // Reference: Piegl & Tiller, "The NURBS Book", algorithms A2.1–A2.2 (knot
    // span / basis functions), A3.1 (De Boor point evaluation) and section
    // 9.2.1 (global curve interpolation via chord-length parameterization +
    // the averaging knot vector). Weights are always 1 (non-rational).

    /// Clamped (open, "Bézier-end") knot vector for `count` control points
    /// and the given degree: `p+1`-fold at each end, uniform interior knots.
    static func clampedKnotVector(controlCount count: Int, degree p: Int) -> [Double] {
        let n = count - 1
        let m = n + p + 1
        guard m >= 0 else { return [] }
        var knots = [Double](repeating: 0, count: m + 1)
        for i in (m - p)...m { knots[i] = 1 }
        let interiorCount = n - p
        if interiorCount > 0 {
            for j in 1...interiorCount {
                knots[p + j] = Double(j) / Double(interiorCount + 1)
            }
        }
        return knots
    }

    private static func findSpan(lastControlIndex n: Int, degree p: Int, t: Double, knots U: [Double]) -> Int {
        if t >= U[n + 1] { return n }
        if t <= U[p] { return p }
        var low = p, high = n + 1
        var mid = (low + high) / 2
        while t < U[mid] || t >= U[mid + 1] {
            if t < U[mid] { high = mid } else { low = mid }
            mid = (low + high) / 2
        }
        return mid
    }

    /// The `p+1` nonzero basis function values `N[span-p...span]` at `t`.
    private static func basisFuns(span i: Int, t: Double, degree p: Int, knots U: [Double]) -> [Double] {
        var N = [Double](repeating: 0, count: p + 1)
        var left = [Double](repeating: 0, count: p + 1)
        var right = [Double](repeating: 0, count: p + 1)
        N[0] = 1
        guard p >= 1 else { return N }
        for j in 1...p {
            left[j] = t - U[i + 1 - j]
            right[j] = U[i + j] - t
            var saved = 0.0
            for r in 0..<j {
                let denom = right[r + 1] + left[j - r]
                let temp = denom > 1e-12 ? N[r] / denom : 0
                N[r] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            N[j] = saved
        }
        return N
    }

    /// De Boor point evaluation at parameter `t` (assumed within the curve's
    /// valid domain `[U[degree], U[controlPoints.count]]`).
    private static func deBoorPoint(t: Double, degree p: Int, knots U: [Double], controlPoints P: [Point3D]) -> Point3D {
        let n = P.count - 1
        guard n >= 0 else { return .zero }
        guard n >= p, U.count == n + p + 2 else { return P.last ?? .zero }
        let k = findSpan(lastControlIndex: n, degree: p, t: t, knots: U)
        var d = (0...p).map { j in P[max(0, min(n, j + k - p))] }
        if p >= 1 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = j + k - p
                    let denom = U[i + p - r + 1] - U[i]
                    let alpha = denom > 1e-12 ? (t - U[i]) / denom : 0
                    d[j] = d[j - 1].scaled(by: 1 - alpha) + d[j].scaled(by: alpha)
                }
            }
        }
        return d[p]
    }

    /// Samples an open (clamped) B-spline curve to a polyline.
    private static func sampleOpenSpline(controlPoints: [Point3D], degree p: Int, samplesPerSpan: Int) -> [Point3D] {
        let knots = clampedKnotVector(controlCount: controlPoints.count, degree: p)
        let n = controlPoints.count - 1
        guard knots.count == n + p + 2 else { return controlPoints }
        let tMin = knots[p], tMax = knots[n + 1]
        let totalSamples = max(2, n * samplesPerSpan)
        return (0...totalSamples).map { s in
            let t = tMin + (tMax - tMin) * Double(s) / Double(totalSamples)
            return deBoorPoint(t: t, degree: p, knots: knots, controlPoints: controlPoints)
        }
    }

    /// Samples a closed (periodic) B-spline curve to a polyline by wrapping
    /// the first `degree` control points onto the tail and evaluating a
    /// uniform (non-clamped) knot vector over exactly one period.
    private static func sampleClosedSpline(controlPoints: [Point3D], degree p: Int, samplesPerSpan: Int) -> [Point3D] {
        let n1 = controlPoints.count
        let extended = controlPoints + Array(controlPoints.prefix(p))
        let knotCount = extended.count + p + 1
        let knots = (0..<knotCount).map(Double.init)
        let tStart = Double(p)
        let tEnd = Double(p + n1)
        let totalSamples = max(2, n1 * samplesPerSpan)
        return (0...totalSamples).map { s in
            let t = tStart + (tEnd - tStart) * Double(s) / Double(totalSamples)
            return deBoorPoint(t: t, degree: p, knots: knots, controlPoints: extended)
        }
    }

    /// Evaluates a `.spline`'s control points/degree/closed-flag to a
    /// polyline approximation, used both for rendering and for every
    /// curve-analysis op (`CurveKernel.polylinePoints`).
    static func sampleSpline(controlPoints: [Point3D], degree: Int, closed: Bool, samplesPerSpan: Int = 12) -> [Point3D] {
        guard controlPoints.count >= 2 else { return controlPoints }
        let p = max(1, min(degree, controlPoints.count - 1))
        if closed, controlPoints.count >= 3 {
            return sampleClosedSpline(controlPoints: controlPoints, degree: p, samplesPerSpan: samplesPerSpan)
        }
        return sampleOpenSpline(controlPoints: controlPoints, degree: p, samplesPerSpan: samplesPerSpan)
    }

    // MARK: - Global curve interpolation (fit a spline through data points)

    /// Dense Gauss-Jordan solve of `A x = rhs` (one linear system, 3 RHS
    /// columns for x/y/z) — `A` is small (one row/column per input point),
    /// so a dense solve is simple and fast enough.
    private static func solveLinearSystem(_ A: [[Double]], rhs: [Point3D]) -> [Point3D] {
        let n = A.count
        guard n > 0 else { return [] }
        var M = A
        var bx = rhs.map { $0.x }, by = rhs.map { $0.y }, bz = rhs.map { $0.z }
        for col in 0..<n {
            var pivotRow = col
            var maxVal = abs(M[col][col])
            for r in (col + 1)..<n where abs(M[r][col]) > maxVal {
                maxVal = abs(M[r][col]); pivotRow = r
            }
            if pivotRow != col {
                M.swapAt(col, pivotRow)
                bx.swapAt(col, pivotRow); by.swapAt(col, pivotRow); bz.swapAt(col, pivotRow)
            }
            let pivot = M[col][col]
            guard abs(pivot) > 1e-12 else { continue }
            for r in 0..<n where r != col {
                let factor = M[r][col] / pivot
                guard factor != 0 else { continue }
                for c in col..<n { M[r][c] -= factor * M[col][c] }
                bx[r] -= factor * bx[col]; by[r] -= factor * by[col]; bz[r] -= factor * bz[col]
            }
        }
        return (0..<n).map { i in
            let pivot = M[i][i]
            guard abs(pivot) > 1e-12 else { return Point3D(x: bx[i], y: by[i], z: bz[i]) }
            return Point3D(x: bx[i] / pivot, y: by[i] / pivot, z: bz[i] / pivot)
        }
    }

    /// Fits a non-rational B-spline that passes exactly through `points`
    /// (Grasshopper's "Interpolate"): chord-length parameterization, the
    /// averaging knot vector, then a linear solve for control points such
    /// that `curve(u_k) == points[k]` for every input point. Degree is
    /// clamped to what the point count supports; returns the actual degree
    /// used alongside the fitted control points.
    static func interpolatedSpline(through points: [Point3D], degree requested: Int = 3, closed: Bool = false) -> (controlPoints: [Point3D], degree: Int) {
        var pts = points
        if closed, pts.count > 2, (pts.first! - pts.last!).length > 1e-9 {
            pts.append(pts.first!)
        }
        guard pts.count >= 2 else { return (pts, 1) }
        let n = pts.count - 1
        let p = max(1, min(requested, n))

        var chordLens = [Double](repeating: 0, count: pts.count)
        var totalLen = 0.0
        for k in 1...n {
            let d = (pts[k] - pts[k - 1]).length
            chordLens[k] = d
            totalLen += d
        }
        guard totalLen > 1e-12 else { return (pts, p) }

        var u = [Double](repeating: 0, count: pts.count)
        for k in 1..<pts.count { u[k] = u[k - 1] + chordLens[k] / totalLen }
        u[n] = 1.0

        // Deliberately reuse `clampedKnotVector` — the exact knot vector
        // `sampleSpline`/`polylinePoints` will reconstruct from just
        // (control point count, degree) when evaluating the fitted curve
        // later. `.spline` doesn't persist a knot vector of its own, so the
        // fit and every future evaluation MUST agree on how knots are
        // derived, or the fitted control points would satisfy a different
        // curve than the one actually rendered (the curve would land near,
        // but not on, the input points).
        let U = clampedKnotVector(controlCount: pts.count, degree: p)

        var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        for k in 0...n {
            let span = findSpan(lastControlIndex: n, degree: p, t: u[k], knots: U)
            let basis = basisFuns(span: span, t: u[k], degree: p, knots: U)
            for j in 0...p { A[k][span - p + j] = basis[j] }
        }
        let controlPoints = solveLinearSystem(A, rhs: pts)
        return (controlPoints, p)
    }

    // MARK: - Length / resampling

    static func cumulativeLengths(for points: [Point3D]) -> [Double] {
        var lengths: [Double] = [0]
        guard points.count > 1 else { return lengths }
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + (points[index] - points[index - 1]).length)
        }
        return lengths
    }

    static func length(of points: [Point3D]) -> Double {
        cumulativeLengths(for: points).last ?? 0
    }

    static func point(atLength target: Double, along points: [Point3D], cumulativeLengths: [Double]) -> Point3D {
        guard points.count > 1 else { return points.first ?? .zero }
        for index in 1..<points.count {
            let startLength = cumulativeLengths[index - 1]
            let endLength = cumulativeLengths[index]
            if target <= endLength || index == points.count - 1 {
                let span = endLength - startLength
                guard span > 1e-9 else { return points[index] }
                let localT = (target - startLength) / span
                let a = points[index - 1], b = points[index]
                return a + (b - a).scaled(by: localT)
            }
        }
        return points.last ?? .zero
    }

    static func resample(_ points: [Point3D], sampleCount: Int) -> [Point3D] {
        guard points.count >= 2, sampleCount >= 2 else { return points }
        if points.count == sampleCount { return points }
        let lengths = cumulativeLengths(for: points)
        let total = lengths.last ?? 0
        guard total > 1e-9 else { return Array(repeating: points[0], count: sampleCount) }
        return (0..<sampleCount).map { index in
            let t = Double(index) / Double(sampleCount - 1)
            return point(atLength: t * total, along: points, cumulativeLengths: lengths)
        }
    }

    static func resample(shape: GeometricShape, sampleCount: Int) -> [Point3D] {
        resample(polylinePoints(for: shape), sampleCount: sampleCount)
    }

    // MARK: - Division / evaluation

    static func divide(_ points: [Point3D], count: Int) -> [Point3D] {
        guard points.count >= 2 else { return points }
        return resample(points, sampleCount: max(2, count))
    }

    static func pointAt(_ points: [Point3D], t: Double) -> Point3D {
        guard !points.isEmpty else { return .zero }
        let lengths = cumulativeLengths(for: points)
        let total = lengths.last ?? 0
        return point(atLength: min(1, max(0, t)) * total, along: points, cumulativeLengths: lengths)
    }

    static func endPoints(_ points: [Point3D]) -> (start: Point3D, end: Point3D)? {
        guard let first = points.first, let last = points.last else { return nil }
        return (first, last)
    }

    static func extend(_ points: [Point3D], startLength: Double, endLength: Double) -> [Point3D] {
        guard points.count >= 2 else { return points }
        var result = points
        if startLength > 0 {
            let dir = (points[0] - points[1]).normalized
            result.insert(points[0] + dir.scaled(by: startLength), at: 0)
        }
        if endLength > 0 {
            let n = points.count
            let dir = (points[n - 1] - points[n - 2]).normalized
            result.append(points[n - 1] + dir.scaled(by: endLength))
        }
        return result
    }

    /// Per-vertex offset via the bisector of adjacent segment normals, in
    /// the curve's own XY footprint. An approximation, not an exact
    /// variable-radius curve offset.
    static func offset(_ points: [Point3D], distance: Double) -> [Point3D] {
        guard points.count >= 2 else { return points }
        let n = points.count
        let closed = n > 2 && (points.first! - points.last!).length < 1e-9

        func segNormal(_ i: Int) -> Point3D {
            let d = points[i + 1] - points[i]
            return Point3D(x: -d.y, y: d.x, z: 0).normalized
        }
        let segCount = n - 1
        let normals = (0..<segCount).map(segNormal)

        var result: [Point3D] = []
        for i in 0..<n {
            let prevN = i > 0 ? normals[i - 1] : (closed ? normals[segCount - 1] : normals[0])
            let nextN = i < segCount ? normals[i] : (closed ? normals[0] : normals[segCount - 1])
            var bisector = prevN + nextN
            if bisector.length < 1e-9 { bisector = prevN }
            bisector = bisector.normalized
            let cosHalf = max(0.35, bisector.dot(nextN))
            result.append(points[i] + bisector.scaled(by: distance / cosHalf))
        }
        return result
    }

    /// Rounds every corner of a closed polygon with a tangent arc,
    /// generalizing the tangent-circle construction `NodeEvaluator` already
    /// uses for `.geoBlendArc`. Assumes a roughly planar (constant-Z) curve.
    static func filletPolygon(_ points: [Point3D], radius: Double, segmentsPerCorner: Int = 12) -> [Point3D] {
        guard points.count >= 3, radius > 0 else { return points }
        var pts = points
        if pts.count > 1, (pts.first! - pts.last!).length < 1e-9 { pts.removeLast() }
        let n = pts.count
        guard n >= 3 else { return points }

        var result: [Point3D] = []
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n]
            let corner = pts[i]
            let next = pts[(i + 1) % n]
            let v1 = prev - corner, v2 = next - corner
            let len1 = v1.length, len2 = v2.length
            guard len1 > 1e-9, len2 > 1e-9 else { result.append(corner); continue }
            let d1 = v1.normalized, d2 = v2.normalized
            let cosAngle = max(-1, min(1, d1.dot(d2)))
            let angle = acos(cosAngle)
            guard angle > 1e-4, angle < .pi - 1e-4 else { result.append(corner); continue }

            let maxTangent = min(len1, len2) * 0.98
            let tangentDist = min(maxTangent, radius / tan(angle / 2))
            let effectiveRadius = tangentDist * tan(angle / 2)
            let p1 = corner + d1.scaled(by: tangentDist)
            let p2 = corner + d2.scaled(by: tangentDist)
            let bisector = (d1 + d2).normalized
            let centerDist = effectiveRadius / max(1e-6, sin(angle / 2))
            let center = corner + bisector.scaled(by: centerDist)

            let startAngle = atan2(p1.y - center.y, p1.x - center.x)
            let endAngle = atan2(p2.y - center.y, p2.x - center.x)
            var sweep = endAngle - startAngle
            while sweep <= -Double.pi { sweep += 2 * .pi }
            while sweep > Double.pi { sweep -= 2 * .pi }

            let segs = max(2, segmentsPerCorner)
            for s in 0...segs {
                let t = Double(s) / Double(segs)
                let a = startAngle + sweep * t
                result.append(Point3D(x: center.x + effectiveRadius * cos(a),
                                       y: center.y + effectiveRadius * sin(a),
                                       z: corner.z))
            }
        }
        if let first = result.first { result.append(first) }
        return result
    }

    static func closestPoint(_ points: [Point3D], to test: Point3D) -> (point: Point3D, t: Double, distance: Double) {
        guard points.count >= 2 else {
            let p = points.first ?? .zero
            return (p, 0, (test - p).length)
        }
        let lengths = cumulativeLengths(for: points)
        let total = lengths.last ?? 1
        var best = points[0]
        var bestDist = Double.infinity
        var bestLen = 0.0
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let ab = b - a
            let abLen2 = ab.dot(ab)
            let tSeg = abLen2 > 1e-12 ? max(0, min(1, (test - a).dot(ab) / abLen2)) : 0
            let proj = a + ab.scaled(by: tSeg)
            let d = (test - proj).length
            if d < bestDist {
                bestDist = d
                best = proj
                bestLen = lengths[i] + tSeg * (lengths[i + 1] - lengths[i])
            }
        }
        return (best, total > 1e-9 ? bestLen / total : 0, bestDist)
    }

    // MARK: - Intersection

    /// Segment-pair scan in the curves' shared XY projection (Z is
    /// interpolated along curve A for the reported hit points).
    static func intersectXY(_ a: [Point3D], _ b: [Point3D]) -> [Point3D] {
        guard a.count >= 2, b.count >= 2 else { return [] }
        var results: [Point3D] = []
        for i in 0..<(a.count - 1) {
            for j in 0..<(b.count - 1) {
                if let hit = segmentIntersectXY(a[i], a[i + 1], b[j], b[j + 1]) {
                    results.append(hit)
                }
            }
        }
        return results
    }

    private static func segmentIntersectXY(_ p1: Point3D, _ p2: Point3D, _ p3: Point3D, _ p4: Point3D) -> Point3D? {
        let denom = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
        guard abs(denom) > 1e-12 else { return nil }
        let t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / denom
        let u = ((p1.x - p3.x) * (p1.y - p2.y) - (p1.y - p3.y) * (p1.x - p2.x)) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return Point3D(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y), z: p1.z + t * (p2.z - p1.z))
    }

    /// Closest-point solution between two finite line segments; `didIntersect`
    /// is true when the segments pass within a small tolerance of each other.
    static func lineLineClosest(_ a0: Point3D, _ a1: Point3D, _ b0: Point3D, _ b1: Point3D) -> (point: Point3D, didIntersect: Bool) {
        let d1 = a1 - a0, d2 = b1 - b0
        let r = a0 - b0
        let aa = d1.dot(d1), ee = d2.dot(d2), ff = d2.dot(r), cc = d1.dot(r)

        var s = 0.0, t = 0.0
        if aa <= 1e-12 && ee <= 1e-12 {
            return (a0, (a0 - b0).length < 1e-4)
        } else if aa <= 1e-12 {
            t = max(0, min(1, ff / ee))
        } else if ee <= 1e-12 {
            s = max(0, min(1, -cc / aa))
        } else {
            let bb = d1.dot(d2)
            let denom = aa * ee - bb * bb
            s = abs(denom) > 1e-12 ? max(0, min(1, (bb * ff - cc * ee) / denom)) : 0
            t = (bb * s + ff) / ee
            if t < 0 { t = 0; s = max(0, min(1, -cc / aa)) }
            else if t > 1 { t = 1; s = max(0, min(1, (bb - cc) / aa)) }
        }
        let pa = a0 + d1.scaled(by: s)
        let pb = b0 + d2.scaled(by: t)
        let dist = (pa - pb).length
        return ((pa + pb).scaled(by: 0.5), dist < 1e-4)
    }
}
