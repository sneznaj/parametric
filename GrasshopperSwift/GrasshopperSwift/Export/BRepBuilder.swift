import Foundation

/// Shared watertight-mesh topology — deduplicated vertices, shared edges,
/// one planar face per triangle — used by both the STEP and IGES exporters,
/// the two formats that model real B-rep entities (vertex/edge/face/shell)
/// rather than a flat triangle soup. Since nothing in this app's geometry
/// pipeline carries true curved surfaces (even the analytic primitives are
/// tessellated to triangles before export), a *faceted* B-rep — flat
/// triangular faces sharing edges/vertices exactly like a real solid model
/// — is the honest, standards-compliant representation here rather than
/// attempting to fit NURBS surfaces to the mesh.
enum BRepBuilder {
    struct Edge { var va: Int; var vb: Int }               // va < vb, canonical direction
    struct Face { var vertexLoop: [Int]; var edgeUses: [(edge: Int, forward: Bool)] }
    struct Solid { var vertices: [Point3D]; var edges: [Edge]; var faces: [Face] }

    static func build(vertices rawVerts: [Point3D], triangles: [Int], epsilon: Double = 1e-5) -> Solid {
        struct VKey: Hashable { var x: Int; var y: Int; var z: Int }
        struct EKey: Hashable { var a: Int; var b: Int }

        var vertMap: [VKey: Int] = [:]
        var vertices: [Point3D] = []
        var remap = [Int](repeating: 0, count: rawVerts.count)
        let scale = 1.0 / epsilon

        for (i, v) in rawVerts.enumerated() {
            let key = VKey(x: Int((v.x * scale).rounded()), y: Int((v.y * scale).rounded()), z: Int((v.z * scale).rounded()))
            if let existing = vertMap[key] {
                remap[i] = existing
            } else {
                let newIndex = vertices.count
                vertMap[key] = newIndex
                vertices.append(v)
                remap[i] = newIndex
            }
        }

        var edgeMap: [EKey: Int] = [:]
        var edges: [Edge] = []
        var faces: [Face] = []

        func use(_ a: Int, _ b: Int) -> (edge: Int, forward: Bool) {
            let forward = a < b
            let key = forward ? EKey(a: a, b: b) : EKey(a: b, b: a)
            if let existing = edgeMap[key] {
                return (existing, forward)
            }
            let idx = edges.count
            edgeMap[key] = idx
            edges.append(Edge(va: key.a, vb: key.b))
            return (idx, forward)
        }

        var t = 0
        while t + 2 < triangles.count {
            let a = remap[triangles[t]]
            let b = remap[triangles[t + 1]]
            let c = remap[triangles[t + 2]]
            if a != b, b != c, a != c {
                faces.append(Face(vertexLoop: [a, b, c], edgeUses: [use(a, b), use(b, c), use(c, a)]))
            }
            t += 3
        }

        return Solid(vertices: vertices, edges: edges, faces: faces)
    }
}
