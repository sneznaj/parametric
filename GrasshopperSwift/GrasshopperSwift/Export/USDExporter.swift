import Foundation

/// Universal Scene Description — ASCII (.usda) plus its zero-compression
/// zip package form (.usdz, e.g. for AR Quick Look / RealityKit). Declares
/// `upAxis = "Z"` in the stage's own metadata rather than remapping
/// coordinates.
enum USDExporter {
    static func exportUSDA(scene: ExportScene) -> String {
        var meshes = ""
        var materials = ""

        for (i, part) in scene.parts.enumerated() {
            let name = ExportUtil.safeName(part.name.isEmpty ? "Shape\(i)" : part.name)
            let matName = "Mat\(i)"

            let faceCounts = Array(repeating: "3", count: part.triangleIndices.count / 3).joined(separator: ", ")
            let faceIndices = part.triangleIndices.map(String.init).joined(separator: ", ")
            let points = part.vertices.map { "(\(ExportUtil.num($0.x)), \(ExportUtil.num($0.y)), \(ExportUtil.num($0.z)))" }.joined(separator: ", ")
            let normals = part.normals.map { "(\(ExportUtil.num($0.x)), \(ExportUtil.num($0.y)), \(ExportUtil.num($0.z)))" }.joined(separator: ", ")
            let color = "(\(ExportUtil.num(part.color.r)), \(ExportUtil.num(part.color.g)), \(ExportUtil.num(part.color.b)))"

            meshes += """
            def Mesh "\(name)"
            {
                int[] faceVertexCounts = [\(faceCounts)]
                int[] faceVertexIndices = [\(faceIndices)]
                point3f[] points = [\(points)]
                normal3f[] normals = [\(normals)] (
                    interpolation = "vertex"
                )
                color3f[] primvars:displayColor = [\(color)] (
                    interpolation = "constant"
                )
                rel material:binding = </World/\(matName)>
                uniform token subdivisionScheme = "none"
            }

            """

            materials += """
            def Material "\(matName)"
            {
                token outputs:surface.connect = </World/\(matName)/PBRShader.outputs:surface>

                def Shader "PBRShader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = \(color)
                    float inputs:metallic = \(ExportUtil.num(part.metalness))
                    float inputs:roughness = \(ExportUtil.num(part.roughness))
                    token outputs:surface
                }
            }

            """
        }

        return """
        #usda 1.0
        (
            defaultPrim = "World"
            upAxis = "Z"
            metersPerUnit = 1
        )

        def Xform "World"
        {
        \(indent(meshes))
        \(indent(materials))}
        """
    }

    static func exportUSDZ(scene: ExportScene, assetName: String) -> Data {
        let usda = exportUSDA(scene: scene)
        let data = Data(usda.utf8)
        let entry = ZipWriter.Entry(name: "\(assetName).usda", data: data, align64: true)
        return ZipWriter.build([entry])
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
    }
}
