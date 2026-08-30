import Foundation

/// FBX ASCII 7.4 (the human-readable FBX variant — no proprietary binary
/// SDK needed to write it, and it's still read by Blender/Maya/3ds Max/
/// Unity/Unreal's importers). One Geometry+Model+Material triple per mesh
/// part, all parented to the implicit root model (id 0).
///
/// Declares `UpAxis: 2` (Z) in GlobalSettings rather than remapping
/// coordinates, since FBX's axis convention is just header metadata.
enum FBXExporter {
    static func export(scene: ExportScene) -> String {
        var objects = ""
        var connections = "Connections:  {\n"

        for (i, part) in scene.parts.enumerated() {
            let geomId = 100_000 + Int64(i) * 10 + 1
            let modelId = 100_000 + Int64(i) * 10 + 2
            let matId = 100_000 + Int64(i) * 10 + 3

            var verts = ""
            for v in part.vertices { verts += "\(ExportUtil.num(v.x)),\(ExportUtil.num(v.y)),\(ExportUtil.num(v.z))," }
            if verts.hasSuffix(",") { verts.removeLast() }

            var polyIndex = ""
            var normalsFlat = ""
            var t = 0
            while t + 2 < part.triangleIndices.count {
                let ia = part.triangleIndices[t]
                let ib = part.triangleIndices[t + 1]
                let ic = part.triangleIndices[t + 2]
                polyIndex += "\(ia),\(ib),\(-(ic + 1)),"
                for idx in [ia, ib, ic] {
                    let n = part.normals[idx]
                    normalsFlat += "\(ExportUtil.num(n.x)),\(ExportUtil.num(n.y)),\(ExportUtil.num(n.z)),"
                }
                t += 3
            }
            if polyIndex.hasSuffix(",") { polyIndex.removeLast() }
            if normalsFlat.hasSuffix(",") { normalsFlat.removeLast() }

            let vertexCount = part.vertices.count * 3
            let indexCount = part.triangleIndices.count
            let normalCount = part.triangleIndices.count * 3
            let name = ExportUtil.safeName(part.name)

            objects += """
                Geometry: \(geomId), "Geometry::\(name)", "Mesh" {
                    Vertices: *\(vertexCount) {
                        a: \(verts)
                    }
                    PolygonVertexIndex: *\(indexCount) {
                        a: \(polyIndex)
                    }
                    LayerElementNormal: 0 {
                        Version: 101
                        Name: ""
                        MappingInformationType: "ByPolygonVertex"
                        ReferenceInformationType: "Direct"
                        Normals: *\(normalCount) {
                            a: \(normalsFlat)
                        }
                    }
                    LayerElementMaterial: 0 {
                        Version: 101
                        Name: ""
                        MappingInformationType: "AllSame"
                        ReferenceInformationType: "IndexToDirect"
                        Materials: *1 {
                            a: 0
                        }
                    }
                    Layer: 0 {
                        Version: 100
                        LayerElement:  {
                            Type: "LayerElementNormal"
                            TypedIndex: 0
                        }
                        LayerElement:  {
                            Type: "LayerElementMaterial"
                            TypedIndex: 0
                        }
                    }
                }
                Model: \(modelId), "Model::\(name)", "Mesh" {
                    Version: 232
                    Properties70:  {
                        P: "Lcl Translation", "Lcl Translation", "", "A",0,0,0
                        P: "Lcl Rotation", "Lcl Rotation", "", "A",0,0,0
                        P: "Lcl Scaling", "Lcl Scaling", "", "A",1,1,1
                    }
                    Shading: T
                    Culling: "CullingOff"
                }
                Material: \(matId), "Material::\(name)", "" {
                    Version: 102
                    ShadingModel: "phong"
                    Properties70:  {
                        P: "DiffuseColor", "Color", "", "A",\(ExportUtil.num(part.color.r)),\(ExportUtil.num(part.color.g)),\(ExportUtil.num(part.color.b))
                        P: "Diffuse", "Vector3D", "Vector", "",\(ExportUtil.num(part.color.r)),\(ExportUtil.num(part.color.g)),\(ExportUtil.num(part.color.b))
                        P: "SpecularColor", "Color", "", "A",\(ExportUtil.num(part.metalness)),\(ExportUtil.num(part.metalness)),\(ExportUtil.num(part.metalness))
                        P: "ReflectionFactor", "double", "Number", "",\(ExportUtil.num(part.metalness))
                    }
                }

            """

            connections += "\tC: \"OO\",\(modelId),0\n"
            connections += "\tC: \"OO\",\(geomId),\(modelId)\n"
            connections += "\tC: \"OO\",\(matId),\(modelId)\n"
        }

        connections += "}\n"

        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())

        return """
        ; FBX 7.4.0 project file
        ; Exported from GrasshopperSwift
        ; ----------------------------------------------------

        FBXHeaderExtension:  {
            FBXHeaderVersion: 1003
            FBXVersion: 7400
            CreationTimeStamp:  {
                Version: 1000
                Year: \(now.year ?? 2026)
                Month: \(now.month ?? 1)
                Day: \(now.day ?? 1)
                Hour: \(now.hour ?? 0)
                Minute: \(now.minute ?? 0)
                Second: \(now.second ?? 0)
                Millisecond: 0
            }
            Creator: "GrasshopperSwift"
        }
        GlobalSettings:  {
            Version: 1000
            Properties70:  {
                P: "UpAxis", "int", "Integer", "",2
                P: "UpAxisSign", "int", "Integer", "",1
                P: "FrontAxis", "int", "Integer", "",1
                P: "FrontAxisSign", "int", "Integer", "",1
                P: "CoordAxis", "int", "Integer", "",0
                P: "CoordAxisSign", "int", "Integer", "",1
                P: "OriginalUpAxis", "int", "Integer", "",2
                P: "OriginalUpAxisSign", "int", "Integer", "",1
                P: "UnitScaleFactor", "double", "Number", "",1
                P: "OriginalUnitScaleFactor", "double", "Number", "",1
            }
        }
        Objects:  {
        \(objects)}
        \(connections)
        """
    }
}
