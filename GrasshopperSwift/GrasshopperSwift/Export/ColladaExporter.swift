import Foundation

/// COLLADA 1.4.1 (.dae) — one `<geometry>`/`<material>`/`<node>` triple per
/// mesh part. Declares `Z_UP` explicitly (matching this app's native world
/// space) instead of remapping coordinates.
enum ColladaExporter {
    static func export(scene: ExportScene) -> String {
        var geometries = ""
        var materials = ""
        var effects = ""
        var nodes = ""

        for (i, part) in scene.parts.enumerated() {
            let gid = "geom\(i)"
            let mid = "mat\(i)"
            let eid = "fx\(i)"

            var positions = ""
            for v in part.vertices { positions += "\(ExportUtil.face(v)) " }
            var normals = ""
            for n in part.normals { normals += "\(ExportUtil.face(n)) " }
            var indices = ""
            for idx in part.triangleIndices { indices += "\(idx) \(idx) " }

            geometries += """
              <geometry id="\(gid)" name="\(ExportUtil.xmlEscape(part.name))">
                <mesh>
                  <source id="\(gid)-positions">
                    <float_array id="\(gid)-positions-array" count="\(part.vertices.count * 3)">\(positions.trimmingCharacters(in: .whitespaces))</float_array>
                    <technique_common>
                      <accessor source="#\(gid)-positions-array" count="\(part.vertices.count)" stride="3">
                        <param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/>
                      </accessor>
                    </technique_common>
                  </source>
                  <source id="\(gid)-normals">
                    <float_array id="\(gid)-normals-array" count="\(part.normals.count * 3)">\(normals.trimmingCharacters(in: .whitespaces))</float_array>
                    <technique_common>
                      <accessor source="#\(gid)-normals-array" count="\(part.normals.count)" stride="3">
                        <param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/>
                      </accessor>
                    </technique_common>
                  </source>
                  <vertices id="\(gid)-vertices">
                    <input semantic="POSITION" source="#\(gid)-positions"/>
                  </vertices>
                  <triangles material="\(mid)-symbol" count="\(part.triangleIndices.count / 3)">
                    <input semantic="VERTEX" source="#\(gid)-vertices" offset="0"/>
                    <input semantic="NORMAL" source="#\(gid)-normals" offset="1"/>
                    <p>\(indices.trimmingCharacters(in: .whitespaces))</p>
                  </triangles>
                </mesh>
              </geometry>

            """

            effects += """
              <effect id="\(eid)">
                <profile_COMMON>
                  <technique sid="common">
                    <phong>
                      <diffuse><color>\(ExportUtil.num(part.color.r)) \(ExportUtil.num(part.color.g)) \(ExportUtil.num(part.color.b)) 1.0</color></diffuse>
                      <specular><color>\(ExportUtil.num(part.metalness)) \(ExportUtil.num(part.metalness)) \(ExportUtil.num(part.metalness)) 1.0</color></specular>
                      <shininess><float>\(ExportUtil.num((1.0 - part.roughness) * 128.0))</float></shininess>
                    </phong>
                  </technique>
                </profile_COMMON>
              </effect>

            """

            materials += "  <material id=\"\(mid)\" name=\"\(mid)\"><instance_effect url=\"#\(eid)\"/></material>\n"

            nodes += """
              <node id="node\(i)" name="\(ExportUtil.xmlEscape(part.name))">
                <instance_geometry url="#\(gid)">
                  <bind_material>
                    <technique_common>
                      <instance_material symbol="\(mid)-symbol" target="#\(mid)"/>
                    </technique_common>
                  </bind_material>
                </instance_geometry>
              </node>

            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
          <asset>
            <created>\(ExportUtil.isoTimestamp)</created>
            <modified>\(ExportUtil.isoTimestamp)</modified>
            <unit name="meter" meter="1.0"/>
            <up_axis>Z_UP</up_axis>
          </asset>
          <library_effects>
        \(effects)  </library_effects>
          <library_materials>
        \(materials)  </library_materials>
          <library_geometries>
        \(geometries)  </library_geometries>
          <library_visual_scenes>
            <visual_scene id="Scene" name="Scene">
        \(nodes)    </visual_scene>
          </library_visual_scenes>
          <scene>
            <instance_visual_scene url="#Scene"/>
          </scene>
        </COLLADA>
        """
    }
}
