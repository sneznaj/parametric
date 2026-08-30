import Foundation

/// Binary little-endian PLY: one merged vertex/face list with per-vertex
/// normal and RGB color (color quantized from each part's material).
enum PLYExporter {
    static func export(scene: ExportScene) -> Data {
        var vertices: [Point3D] = []
        var normals: [Point3D] = []
        var colors: [(UInt8, UInt8, UInt8)] = []
        var faces: [(Int, Int, Int)] = []

        for part in scene.parts {
            let offset = vertices.count
            vertices.append(contentsOf: part.vertices)
            normals.append(contentsOf: part.normals)
            let rgb = quantize(part.color)
            colors.append(contentsOf: Array(repeating: rgb, count: part.vertices.count))
            var t = 0
            while t + 2 < part.triangleIndices.count {
                faces.append((
                    part.triangleIndices[t] + offset,
                    part.triangleIndices[t + 1] + offset,
                    part.triangleIndices[t + 2] + offset
                ))
                t += 3
            }
        }

        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment Exported from GrasshopperSwift\n"
        header += "element vertex \(vertices.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "element face \(faces.count)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"

        var w = BinaryWriter()
        w.append(ascii: header)

        for i in 0..<vertices.count {
            let v = vertices[i]
            let n = i < normals.count ? normals[i] : .zero
            let c = colors[i]
            w.append(Float(v.x)); w.append(Float(v.y)); w.append(Float(v.z))
            w.append(Float(n.x)); w.append(Float(n.y)); w.append(Float(n.z))
            w.append(c.0); w.append(c.1); w.append(c.2)
        }

        for f in faces {
            w.append(UInt8(3))
            w.append(Int32(f.0)); w.append(Int32(f.1)); w.append(Int32(f.2))
        }

        return w.data
    }

    private static func quantize(_ c: (r: Double, g: Double, b: Double)) -> (UInt8, UInt8, UInt8) {
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return (q(c.r), q(c.g), q(c.b))
    }
}
