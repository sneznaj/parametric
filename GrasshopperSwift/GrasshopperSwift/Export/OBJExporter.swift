import Foundation

/// Wavefront OBJ + companion MTL. The one exporter that also carries raw
/// curve/line geometry (via `l` elements) alongside triangle meshes, since
/// OBJ is the most forgiving, universally-supported text format for it.
enum OBJExporter {
    struct Output {
        let obj: String
        let mtl: String
    }

    static func export(scene: ExportScene, mtlFileName: String) -> Output {
        var obj = "# Exported from GrasshopperSwift\n"
        obj += "mtllib \(mtlFileName)\n\n"
        var mtl = "# Exported from GrasshopperSwift\n\n"

        var vertexOffset = 1   // OBJ indices are 1-based
        var normalOffset = 1

        for (i, part) in scene.parts.enumerated() {
            let matName = "mat\(i)"
            obj += "o \(part.name)\n"
            obj += "usemtl \(matName)\n"
            for v in part.vertices { obj += "v \(ExportUtil.face(v))\n" }
            for n in part.normals { obj += "vn \(ExportUtil.face(n))\n" }
            var t = 0
            while t + 2 < part.triangleIndices.count {
                let a = part.triangleIndices[t] + vertexOffset
                let b = part.triangleIndices[t + 1] + vertexOffset
                let c = part.triangleIndices[t + 2] + vertexOffset
                let na = part.triangleIndices[t] + normalOffset
                let nb = part.triangleIndices[t + 1] + normalOffset
                let nc = part.triangleIndices[t + 2] + normalOffset
                obj += "f \(a)//\(na) \(b)//\(nb) \(c)//\(nc)\n"
                t += 3
            }
            obj += "\n"
            vertexOffset += part.vertices.count
            normalOffset += part.normals.count

            mtl += "newmtl \(matName)\n"
            mtl += "Kd \(ExportUtil.num(part.color.r)) \(ExportUtil.num(part.color.g)) \(ExportUtil.num(part.color.b))\n"
            mtl += "Ka 0.0 0.0 0.0\n"
            mtl += "Ks \(ExportUtil.num(part.metalness)) \(ExportUtil.num(part.metalness)) \(ExportUtil.num(part.metalness))\n"
            mtl += "d 1.0\n"
            mtl += "illum 2\n"
            // Non-standard but widely-recognized PBR extension (Blender et al.).
            mtl += "Pr \(ExportUtil.num(part.roughness))\n"
            mtl += "Pm \(ExportUtil.num(part.metalness))\n\n"
        }

        for (i, line) in scene.polylines.enumerated() {
            let matName = "line\(i)"
            obj += "o Curve\(i)\n"
            obj += "usemtl \(matName)\n"
            for v in line.points { obj += "v \(ExportUtil.face(v))\n" }
            let indices = (vertexOffset..<(vertexOffset + line.points.count)).map { $0 }
            let seq = line.closed ? indices + [indices[0]] : indices
            obj += "l " + seq.map(String.init).joined(separator: " ") + "\n\n"
            vertexOffset += line.points.count

            mtl += "newmtl \(matName)\n"
            mtl += "Kd \(ExportUtil.num(line.color.r)) \(ExportUtil.num(line.color.g)) \(ExportUtil.num(line.color.b))\n"
            mtl += "illum 0\n\n"
        }

        return Output(obj: obj, mtl: mtl)
    }
}
