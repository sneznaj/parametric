import Foundation

/// 3D Manufacturing Format (.3mf) — an OPC/zip package wrapping an XML mesh
/// model, plus the "Materials and Properties" extension for per-object flat
/// color. Curve-only geometry has no 3MF representation and is dropped.
enum ThreeMFExporter {
    static func export(scene: ExportScene) -> Data {
        let colorGroupId = 1
        var colorEntries = ""
        for part in scene.parts {
            colorEntries += "      <m:color color=\"\(hex(part.color))\"/>\n"
        }

        var objects = ""
        var items = ""
        var nextId = 2
        for part in scene.parts {
            let objId = nextId
            nextId += 1
            let colorIndex = objId - 2

            var vertices = ""
            for v in part.vertices {
                vertices += "          <vertex x=\"\(ExportUtil.num(v.x))\" y=\"\(ExportUtil.num(v.y))\" z=\"\(ExportUtil.num(v.z))\"/>\n"
            }
            var triangles = ""
            var t = 0
            while t + 2 < part.triangleIndices.count {
                let a = part.triangleIndices[t], b = part.triangleIndices[t + 1], c = part.triangleIndices[t + 2]
                triangles += "          <triangle v1=\"\(a)\" v2=\"\(b)\" v3=\"\(c)\"/>\n"
                t += 3
            }

            objects += """
                <object id="\(objId)" type="model" pid="\(colorGroupId)" pindex="\(colorIndex)">
                  <mesh>
                    <vertices>
            \(vertices)        </vertices>
                    <triangles>
            \(triangles)        </triangles>
                  </mesh>
                </object>

            """
            items += "    <item objectid=\"\(objId)\"/>\n"
        }

        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" \
        xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" \
        xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02">
          <metadata name="Application">GrasshopperSwift</metadata>
          <resources>
            <m:colorgroup id="\(colorGroupId)">
        \(colorEntries)    </m:colorgroup>
        \(objects)  </resources>
          <build>
        \(items)  </build>
        </model>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
        </Types>
        """

        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rel0" Target="/3D/3dmodel.model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """

        let entries = [
            ZipWriter.Entry(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            ZipWriter.Entry(name: "_rels/.rels", data: Data(rels.utf8)),
            ZipWriter.Entry(name: "3D/3dmodel.model", data: Data(model.utf8))
        ]
        return ZipWriter.build(entries)
    }

    private static func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
        func q(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", q(c.r), q(c.g), q(c.b))
    }
}
