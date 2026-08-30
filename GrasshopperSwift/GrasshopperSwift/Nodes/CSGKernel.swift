import Foundation

/// Solid boolean operations (Union / Difference / Intersection) via a
/// BSP-tree polygon-clipping algorithm — the classic "csg.js" approach
/// (Evan Wallace), ported to Swift and operating on the app's triangle
/// meshes (`MeshKernel.MeshData`). This is an approximate solid kernel, not
/// a NURBS/B-rep kernel: results are triangle soups re-triangulated by
/// fanning each clipped polygon fragment (safe because clipping a convex
/// triangle by a plane always yields convex fragments). Adequate for the
/// primitive/mesh shapes this app can produce; thin/coincident geometry may
/// show small artifacts, which is an accepted tradeoff for not embedding a
/// full CAD kernel.
enum CSGKernel {

    private struct Plane {
        static let epsilon = 1e-5
        var normal: Point3D
        var w: Double

        static func from(_ a: Point3D, _ b: Point3D, _ c: Point3D) -> Plane {
            let n = (b - a).cross(c - a).normalized
            return Plane(normal: n, w: n.dot(a))
        }

        mutating func flip() {
            normal = normal.scaled(by: -1)
            w = -w
        }

        /// Splits `polygon` against this plane into up to two coplanar
        /// buckets (front/back-facing relative to this plane) or
        /// front/back polygons for polygons that straddle the plane.
        func splitPolygon(_ polygon: Polygon,
                           coplanarFront: inout [Polygon], coplanarBack: inout [Polygon],
                           front: inout [Polygon], back: inout [Polygon]) {
            let coplanarT = 0, frontT = 1, backT = 2, spanningT = 3
            var polygonType = 0
            var types: [Int] = []
            types.reserveCapacity(polygon.vertices.count)
            for v in polygon.vertices {
                let t = normal.dot(v) - w
                let type = t < -Plane.epsilon ? backT : (t > Plane.epsilon ? frontT : coplanarT)
                polygonType |= type
                types.append(type)
            }

            switch polygonType {
            case coplanarT:
                if normal.dot(polygon.plane.normal) > 0 { coplanarFront.append(polygon) } else { coplanarBack.append(polygon) }
            case frontT:
                front.append(polygon)
            case backT:
                back.append(polygon)
            default: // spanning
                var f: [Point3D] = [], b: [Point3D] = []
                let n = polygon.vertices.count
                for i in 0..<n {
                    let j = (i + 1) % n
                    let ti = types[i], tj = types[j]
                    let vi = polygon.vertices[i], vj = polygon.vertices[j]
                    if ti != backT { f.append(vi) }
                    if ti != frontT { b.append(vi) }
                    if (ti | tj) == spanningT {
                        let denom = normal.dot(vj - vi)
                        let t = abs(denom) > 1e-12 ? (w - normal.dot(vi)) / denom : 0
                        let v = vi + (vj - vi).scaled(by: t)
                        f.append(v)
                        b.append(v)
                    }
                }
                if f.count >= 3 { front.append(Polygon(vertices: f)) }
                if b.count >= 3 { back.append(Polygon(vertices: b)) }
            }
        }
    }

    private struct Polygon {
        var vertices: [Point3D]
        var plane: Plane

        init(vertices: [Point3D]) {
            self.vertices = vertices
            self.plane = Plane.from(vertices[0], vertices[1], vertices[2])
        }

        mutating func flip() {
            vertices.reverse()
            plane.flip()
        }
    }

    private final class Node {
        var plane: Plane?
        var front: Node?
        var back: Node?
        var polygons: [Polygon] = []

        init(_ polygons: [Polygon] = []) {
            if !polygons.isEmpty { build(polygons) }
        }

        func clone() -> Node {
            let n = Node()
            n.plane = plane
            n.polygons = polygons
            n.front = front?.clone()
            n.back = back?.clone()
            return n
        }

        func invert() {
            for i in polygons.indices { polygons[i].flip() }
            plane?.flip()
            front?.invert()
            back?.invert()
            swap(&front, &back)
        }

        func clipPolygons(_ polys: [Polygon]) -> [Polygon] {
            guard let plane else { return polys }
            var frontP: [Polygon] = [], backP: [Polygon] = []
            for p in polys {
                var cf: [Polygon] = [], cb: [Polygon] = []
                plane.splitPolygon(p, coplanarFront: &cf, coplanarBack: &cb, front: &frontP, back: &backP)
                frontP.append(contentsOf: cf)
                backP.append(contentsOf: cb)
            }
            var resultFront = front?.clipPolygons(frontP) ?? frontP
            let resultBack = back?.clipPolygons(backP) ?? []
            resultFront.append(contentsOf: resultBack)
            return resultFront
        }

        func clipTo(_ bsp: Node) {
            polygons = bsp.clipPolygons(polygons)
            front?.clipTo(bsp)
            back?.clipTo(bsp)
        }

        func allPolygons() -> [Polygon] {
            var result = polygons
            if let front { result.append(contentsOf: front.allPolygons()) }
            if let back { result.append(contentsOf: back.allPolygons()) }
            return result
        }

        func build(_ polys: [Polygon]) {
            guard !polys.isEmpty else { return }
            if plane == nil { plane = polys[0].plane }
            guard let plane else { return }
            var frontP: [Polygon] = [], backP: [Polygon] = []
            for p in polys {
                var cf: [Polygon] = [], cb: [Polygon] = []
                plane.splitPolygon(p, coplanarFront: &cf, coplanarBack: &cb, front: &frontP, back: &backP)
                polygons.append(contentsOf: cf)
                polygons.append(contentsOf: cb)
            }
            if !frontP.isEmpty {
                let f = front ?? Node()
                f.build(frontP)
                front = f
            }
            if !backP.isEmpty {
                let b = back ?? Node()
                b.build(backP)
                back = b
            }
        }
    }

    private static func node(from mesh: MeshKernel.MeshData) -> Node {
        var polys: [Polygon] = []
        let tris = mesh.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let a = mesh.vertices[tris[t]], b = mesh.vertices[tris[t + 1]], c = mesh.vertices[tris[t + 2]]
            polys.append(Polygon(vertices: [a, b, c]))
            t += 3
        }
        return Node(polys)
    }

    /// Fan-triangulates every resulting polygon fragment (safe since
    /// clipped fragments of a triangle stay convex).
    private static func mesh(from node: Node) -> MeshKernel.MeshData {
        var verts: [Point3D] = []
        var idx: [Int] = []
        for poly in node.allPolygons() where poly.vertices.count >= 3 {
            let base = verts.count
            verts.append(contentsOf: poly.vertices)
            for i in 1..<(poly.vertices.count - 1) {
                idx.append(contentsOf: [base, base + i, base + i + 1])
            }
        }
        return (verts, idx)
    }

    static func union(_ a: MeshKernel.MeshData, _ b: MeshKernel.MeshData) -> MeshKernel.MeshData {
        let ac = node(from: a), bc = node(from: b)
        ac.clipTo(bc)
        bc.clipTo(ac)
        bc.invert()
        bc.clipTo(ac)
        bc.invert()
        ac.build(bc.allPolygons())
        return mesh(from: ac)
    }

    static func subtract(_ a: MeshKernel.MeshData, _ b: MeshKernel.MeshData) -> MeshKernel.MeshData {
        let ac = node(from: a), bc = node(from: b)
        ac.invert()
        ac.clipTo(bc)
        bc.clipTo(ac)
        bc.invert()
        bc.clipTo(ac)
        bc.invert()
        ac.build(bc.allPolygons())
        ac.invert()
        return mesh(from: ac)
    }

    static func intersect(_ a: MeshKernel.MeshData, _ b: MeshKernel.MeshData) -> MeshKernel.MeshData {
        let ac = node(from: a), bc = node(from: b)
        ac.invert()
        bc.clipTo(ac)
        bc.invert()
        ac.clipTo(bc)
        bc.clipTo(ac)
        ac.build(bc.allPolygons())
        ac.invert()
        return mesh(from: ac)
    }
}
