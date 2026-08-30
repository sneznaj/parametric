import Foundation

/// Binary STL — flat facet list with per-triangle face normals (no vertex
/// sharing/smoothing, no color/material, matching the format's scope).
/// Curve-only geometry (`scene.polylines`) has no STL representation and is
/// silently dropped, since STL can only carry closed triangle facets.
enum STLExporter {
    static func export(scene: ExportScene) -> Data {
        var triangleCount = 0
        for part in scene.parts { triangleCount += part.triangleIndices.count / 3 }

        var w = BinaryWriter()
        let header = "Binary STL exported from GrasshopperSwift"
        var headerBytes = Array(header.utf8)
        headerBytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 80 - headerBytes.count)))
        w.append(Array(headerBytes.prefix(80)))
        w.append(UInt32(triangleCount))

        for part in scene.parts {
            var t = 0
            while t + 2 < part.triangleIndices.count {
                let a = part.vertices[part.triangleIndices[t]]
                let b = part.vertices[part.triangleIndices[t + 1]]
                let c = part.vertices[part.triangleIndices[t + 2]]
                let n = faceNormal(a, b, c)
                w.append(Float(n.x)); w.append(Float(n.y)); w.append(Float(n.z))
                w.append(Float(a.x)); w.append(Float(a.y)); w.append(Float(a.z))
                w.append(Float(b.x)); w.append(Float(b.y)); w.append(Float(b.z))
                w.append(Float(c.x)); w.append(Float(c.y)); w.append(Float(c.z))
                w.append(UInt16(0))  // attribute byte count
                t += 3
            }
        }
        return w.data
    }

    private static func faceNormal(_ a: Point3D, _ b: Point3D, _ c: Point3D) -> Point3D {
        (b - a).cross(c - a).normalized
    }
}
