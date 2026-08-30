import Foundation

// MARK: - Export intermediate representation
//
// All 3D exporters (OBJ/STL/PLY/glTF/GLB/Collada/FBX/USD/USDZ/STEP/IGES/3MF)
// consume this shared, format-agnostic scene rather than walking
// `GeometricShape` themselves. Coordinates are left exactly as they appear
// in the app's world space (Z-up, see `PathTracerScene`'s "App-space (Z-up)"
// note) — each exporter decides for itself whether to declare that axis
// convention in its header/metadata or remap it, since formats differ in
// what they support.

/// One paintable triangle-mesh part, with smooth per-vertex normals and the
/// base color/metalness/roughness pulled from its `Material3D`.
struct ExportMeshPart {
    var name: String
    var vertices: [Point3D]
    var normals: [Point3D]        // same count/order as `vertices`
    var triangleIndices: [Int]    // stride 3, CCW winding (outward-facing)
    var color: (r: Double, g: Double, b: Double)
    var metalness: Double
    var roughness: Double
}

/// A raw curve — kept separate from the triangle parts for the one format
/// (OBJ) that can carry wireframe/line geometry alongside meshes. Every
/// other exporter ignores these, since STL/PLY/glTF/3MF/STEP/IGES/etc. are
/// fundamentally solid/surface formats.
struct ExportPolyline {
    var points: [Point3D]
    var closed: Bool
    var color: (r: Double, g: Double, b: Double)
}

struct ExportScene {
    var parts: [ExportMeshPart]
    var polylines: [ExportPolyline]

    var isEmpty: Bool { parts.isEmpty && polylines.isEmpty }

    var bounds: (min: Point3D, max: Point3D)? {
        var lo = Point3D(x: .infinity, y: .infinity, z: .infinity)
        var hi = Point3D(x: -.infinity, y: -.infinity, z: -.infinity)
        var touched = false
        func expand(_ p: Point3D) {
            touched = true
            lo = Point3D(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
            hi = Point3D(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
        }
        for part in parts { part.vertices.forEach(expand) }
        for line in polylines { line.points.forEach(expand) }
        return touched ? (lo, hi) : nil
    }
}

enum ExportSceneBuilder {

    /// Builds an `ExportScene` from the 3D-pipeline shapes shown in the
    /// viewport (i.e. already filtered to `!isStyled2D`, same as
    /// `GeometryPreviewView.modeShapes` for any non-2D view mode).
    static func build(from shapes: [GeometricShape]) -> ExportScene {
        var parts: [ExportMeshPart] = []
        var polylines: [ExportPolyline] = []
        for (index, shape) in shapes.enumerated() {
            append(shape, index: index, parts: &parts, polylines: &polylines)
        }
        return ExportScene(parts: parts, polylines: polylines)
    }

    private static func append(
        _ shape: GeometricShape, index: Int,
        parts: inout [ExportMeshPart], polylines: inout [ExportPolyline]
    ) {
        let material = shape.material()
        let color = (material.r, material.g, material.b)
        let name = "Shape\(index)"

        func addMesh(_ md: MeshKernel.MeshData) {
            guard !md.vertices.isEmpty, !md.triangleIndices.isEmpty else { return }
            let normals = MeshKernel.vertexNormals(md)
            parts.append(ExportMeshPart(
                name: name, vertices: md.vertices, normals: normals,
                triangleIndices: md.triangleIndices,
                color: color, metalness: material.metalness, roughness: material.roughness
            ))
        }

        switch shape.unwrapForRendering() {
        case .point, .label:
            return

        case .line(let a, let b):
            polylines.append(ExportPolyline(points: [a, b], closed: false, color: color))

        case .polyline(let pts):
            guard pts.count >= 2 else { return }
            polylines.append(ExportPolyline(points: pts, closed: false, color: color))

        case .spline(let cps, let degree, let closed):
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed)
            guard pts.count >= 2 else { return }
            polylines.append(ExportPolyline(points: pts, closed: closed, color: color))

        case .circle(let c, let r):
            // Matches the Realistic viewport, which renders a lone 3D circle
            // as a filled disc (`filament_createDisc`), not a bare curve.
            let segments = 64
            let loop = (0..<segments).map { i -> Point3D in
                let a = Double(i) / Double(segments) * 2 * .pi
                return Point3D(x: c.x + r * cos(a), y: c.y + r * sin(a), z: c.z)
            }
            addMesh(MeshKernel.fanCap(loop: loop, flipped: false))

        case .polygon(let pts):
            // Matches the Realistic viewport's filled `filament_createPolygon`.
            guard pts.count >= 3 else { return }
            addMesh(MeshKernel.fanCap(loop: pts, flipped: false))

        case .surfaceStrip(let a, let b):
            guard a.count == b.count, a.count >= 2 else { return }
            addMesh(MeshKernel.stitchRings([a, b], closeLoop: false))

        case let inner:
            if let md = MeshKernel.meshData(from: inner) {
                addMesh(md)
            }
        }
    }
}
