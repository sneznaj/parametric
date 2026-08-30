import Foundation

/// glTF 2.0 binary container (.glb) — a single self-contained file (JSON +
/// binary buffer chunk), which is why "glTF/GLB" is offered as one export
/// action rather than two.
///
/// glTF mandates a Y-up axis convention with no per-file override, so unlike
/// every other exporter here (which declares this app's native Z-up axis in
/// the target format's own metadata), this one remaps coordinates via
/// (x, y, z) -> (x, z, -y) — the same rotation `FilamentRenderView` and
/// `PathTracerScene` use to feed Filament. That map has determinant +1 (a
/// pure rotation, not a reflection), so triangle winding and normals stay
/// correct with no index-order flip needed.
enum GLTFExporter {
    static func exportGLB(scene: ExportScene) -> Data {
        var bin = BinaryWriter()

        struct MeshAccessors { let posAcc: Int; let normAcc: Int; let idxAcc: Int; let vertexCount: Int; let triCount: Int }
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var meshAccessors: [MeshAccessors] = []

        func addBufferView(byteOffset: Int, byteLength: Int, target: Int) -> Int {
            bufferViews.append(["buffer": 0, "byteOffset": byteOffset, "byteLength": byteLength, "target": target])
            return bufferViews.count - 1
        }

        for part in scene.parts {
            // POSITION
            var minP = [Double.infinity, .infinity, .infinity]
            var maxP = [-Double.infinity, -Double.infinity, -Double.infinity]
            let posStart = bin.data.count
            for v in part.vertices {
                let r = remap(v)
                bin.append(Float(r.x)); bin.append(Float(r.y)); bin.append(Float(r.z))
                minP[0] = min(minP[0], r.x); minP[1] = min(minP[1], r.y); minP[2] = min(minP[2], r.z)
                maxP[0] = max(maxP[0], r.x); maxP[1] = max(maxP[1], r.y); maxP[2] = max(maxP[2], r.z)
            }
            let posLen = bin.data.count - posStart
            bin.pad(to: 4)
            let posBV = addBufferView(byteOffset: posStart, byteLength: posLen, target: 34962)
            accessors.append([
                "bufferView": posBV, "componentType": 5126, "count": part.vertices.count,
                "type": "VEC3", "min": minP, "max": maxP
            ])
            let posAcc = accessors.count - 1

            // NORMAL
            let normStart = bin.data.count
            for n in part.normals {
                let r = remap(n)
                bin.append(Float(r.x)); bin.append(Float(r.y)); bin.append(Float(r.z))
            }
            let normLen = bin.data.count - normStart
            bin.pad(to: 4)
            let normBV = addBufferView(byteOffset: normStart, byteLength: normLen, target: 34962)
            accessors.append(["bufferView": normBV, "componentType": 5126, "count": part.normals.count, "type": "VEC3"])
            let normAcc = accessors.count - 1

            // INDICES (unsigned int — simplest, always valid regardless of vertex count)
            let idxStart = bin.data.count
            for i in part.triangleIndices { bin.append(UInt32(i)) }
            let idxLen = bin.data.count - idxStart
            bin.pad(to: 4)
            let idxBV = addBufferView(byteOffset: idxStart, byteLength: idxLen, target: 34963)
            accessors.append(["bufferView": idxBV, "componentType": 5125, "count": part.triangleIndices.count, "type": "SCALAR"])
            let idxAcc = accessors.count - 1

            meshAccessors.append(MeshAccessors(posAcc: posAcc, normAcc: normAcc, idxAcc: idxAcc,
                                                vertexCount: part.vertices.count, triCount: part.triangleIndices.count))
        }

        let totalBinLength = bin.data.count

        var materials: [[String: Any]] = []
        for part in scene.parts {
            materials.append([
                "name": part.name,
                "pbrMetallicRoughness": [
                    "baseColorFactor": [part.color.r, part.color.g, part.color.b, 1.0],
                    "metallicFactor": part.metalness,
                    "roughnessFactor": part.roughness
                ]
            ])
        }

        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        var nodeIndices: [Int] = []
        for (i, ma) in meshAccessors.enumerated() {
            meshes.append([
                "name": scene.parts[i].name,
                "primitives": [[
                    "attributes": ["POSITION": ma.posAcc, "NORMAL": ma.normAcc],
                    "indices": ma.idxAcc,
                    "material": i,
                    "mode": 4
                ]]
            ])
            nodes.append(["name": scene.parts[i].name, "mesh": i])
            nodeIndices.append(i)
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "GrasshopperSwift"],
            "scene": 0,
            "scenes": [["nodes": nodeIndices]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": totalBinLength]]
        ]

        let jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        var jsonBytes = [UInt8](jsonData)
        while jsonBytes.count % 4 != 0 { jsonBytes.append(0x20) } // space-pad per spec

        var out = BinaryWriter()
        // GLB header
        out.append(ascii: "glTF")
        out.append(UInt32(2))
        let totalLength = 12 + (8 + jsonBytes.count) + (8 + totalBinLength)
        out.append(UInt32(totalLength))
        // JSON chunk
        out.append(UInt32(jsonBytes.count))
        out.append(UInt32(0x4E4F534A))  // "JSON"
        out.append(jsonBytes)
        // BIN chunk
        out.append(UInt32(totalBinLength))
        out.append(UInt32(0x004E4942))  // "BIN\0"
        out.append(bin.data)

        return out.data
    }

    private static func remap(_ p: Point3D) -> Point3D {
        Point3D(x: p.x, y: p.z, z: -p.y)
    }
}
