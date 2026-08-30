import Foundation

/// ISO-10303-21 (STEP) — a classic faceted B-rep: one planar `ADVANCED_FACE`
/// per triangle, sharing `EDGE_CURVE`/`VERTEX_POINT` entities via
/// `BRepBuilder`'s topology so each solid is a proper watertight
/// `MANIFOLD_SOLID_BREP` rather than disconnected triangles. This uses only
/// classic AP203/214 entities (no AP242 `TESSELLATED_SOLID`) for the widest
/// possible reader compatibility, since nothing in this app's data model
/// carries true curved surfaces to preserve anyway.
enum STEPExporter {
    private final class Writer {
        private(set) var lines: [String] = []
        private var nextId = 1
        func add(_ body: String) -> Int {
            let id = nextId
            nextId += 1
            lines.append("#\(id) = \(body);")
            return id
        }
    }

    static func export(scene: ExportScene, name: String = "GrasshopperSwiftExport") -> String {
        let w = Writer()
        var solidIds: [Int] = []

        for part in scene.parts {
            let solid = BRepBuilder.build(vertices: part.vertices, triangles: part.triangleIndices)
            guard !solid.faces.isEmpty else { continue }
            if let id = emit(solid: solid, name: part.name, w: w) {
                solidIds.append(id)
            }
        }

        guard !solidIds.isEmpty else {
            return header(name: name) + "DATA;\nENDSEC;\nEND-ISO-10303-21;\n"
        }

        let appCtx = w.add("APPLICATION_CONTEXT('automotive_design')")
        _ = w.add("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2010,#\(appCtx))")
        let prodCtx = w.add("PRODUCT_CONTEXT('',#\(appCtx),'mechanical')")
        let product = w.add("PRODUCT('\(ExportUtil.stepString(name))','\(ExportUtil.stepString(name))','',(#\(prodCtx)))")
        let formation = w.add("PRODUCT_DEFINITION_FORMATION('','',#\(product))")
        let defCtx = w.add("PRODUCT_DEFINITION_CONTEXT('part definition',#\(appCtx),'design')")
        let def = w.add("PRODUCT_DEFINITION('design','',#\(formation),#\(defCtx))")
        let defShape = w.add("PRODUCT_DEFINITION_SHAPE('','',#\(def))")

        let lengthUnit = w.add("(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.))")
        let angleUnit = w.add("(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.))")
        let solidAngleUnit = w.add("(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT())")
        let uncertainty = w.add("UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.0E-5),#\(lengthUnit),'distance_accuracy_value','confusion accuracy')")
        let geomCtx = w.add(
            "(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#\(uncertainty))) " +
            "GLOBAL_UNIT_ASSIGNED_CONTEXT((#\(lengthUnit),#\(angleUnit),#\(solidAngleUnit))) " +
            "REPRESENTATION_CONTEXT('Context','3D'))"
        )

        let items = solidIds.map { "#\($0)" }.joined(separator: ",")
        let shapeRep = w.add("ADVANCED_BREP_SHAPE_REPRESENTATION('',(\(items)),#\(geomCtx))")
        _ = w.add("SHAPE_DEFINITION_REPRESENTATION(#\(defShape),#\(shapeRep))")

        var out = header(name: name)
        out += "DATA;\n"
        for line in w.lines { out += line + "\n" }
        out += "ENDSEC;\nEND-ISO-10303-21;\n"
        return out
    }

    /// Emits one solid's full topology and returns its MANIFOLD_SOLID_BREP id.
    private static func emit(solid: BRepBuilder.Solid, name: String, w: Writer) -> Int? {
        guard !solid.vertices.isEmpty, !solid.faces.isEmpty else { return nil }

        // Vertices
        var vertexIds: [Int] = []
        vertexIds.reserveCapacity(solid.vertices.count)
        for v in solid.vertices {
            let pt = w.add("CARTESIAN_POINT('',(\(ExportUtil.num(v.x)),\(ExportUtil.num(v.y)),\(ExportUtil.num(v.z))))")
            vertexIds.append(w.add("VERTEX_POINT('',#\(pt))"))
        }

        // Edges — each an EDGE_CURVE over an infinite LINE, trimmed by its vertices.
        var edgeCurveIds: [Int] = []
        edgeCurveIds.reserveCapacity(solid.edges.count)
        for edge in solid.edges {
            let a = solid.vertices[edge.va]
            let b = solid.vertices[edge.vb]
            let dir = (b - a).normalized
            let originPt = w.add("CARTESIAN_POINT('',(\(ExportUtil.num(a.x)),\(ExportUtil.num(a.y)),\(ExportUtil.num(a.z))))")
            let dirId = w.add("DIRECTION('',(\(ExportUtil.num(dir.x)),\(ExportUtil.num(dir.y)),\(ExportUtil.num(dir.z))))")
            let vec = w.add("VECTOR('',#\(dirId),1.0)")
            let line = w.add("LINE('',#\(originPt),#\(vec))")
            edgeCurveIds.append(w.add(
                "EDGE_CURVE('',#\(vertexIds[edge.va]),#\(vertexIds[edge.vb]),#\(line),.T.)"
            ))
        }

        // Faces — one planar ADVANCED_FACE per triangle.
        var faceIds: [Int] = []
        faceIds.reserveCapacity(solid.faces.count)
        for face in solid.faces {
            let a = solid.vertices[face.vertexLoop[0]]
            let b = solid.vertices[face.vertexLoop[1]]
            let c = solid.vertices[face.vertexLoop[2]]
            let normal = (b - a).cross(c - a).normalized
            var refDir = (b - a).normalized
            let proj = refDir.dot(normal)
            refDir = (refDir - normal.scaled(by: proj)).normalized
            if refDir.length < 1e-9 { refDir = Point3D(x: 1, y: 0, z: 0) }

            let originPt = w.add("CARTESIAN_POINT('',(\(ExportUtil.num(a.x)),\(ExportUtil.num(a.y)),\(ExportUtil.num(a.z))))")
            let axisDir = w.add("DIRECTION('',(\(ExportUtil.num(normal.x)),\(ExportUtil.num(normal.y)),\(ExportUtil.num(normal.z))))")
            let refDirId = w.add("DIRECTION('',(\(ExportUtil.num(refDir.x)),\(ExportUtil.num(refDir.y)),\(ExportUtil.num(refDir.z))))")
            let placement = w.add("AXIS2_PLACEMENT_3D('',#\(originPt),#\(axisDir),#\(refDirId))")
            let plane = w.add("PLANE('',#\(placement))")

            let orientedEdges = face.edgeUses.map { use -> Int in
                let sense = use.forward ? ".T." : ".F."
                return w.add("ORIENTED_EDGE('',*,*,#\(edgeCurveIds[use.edge]),\(sense))")
            }
            let loop = w.add("EDGE_LOOP('',(\(orientedEdges.map { "#\($0)" }.joined(separator: ","))))")
            let bound = w.add("FACE_OUTER_BOUND('',#\(loop),.T.)")
            faceIds.append(w.add("ADVANCED_FACE('',(#\(bound)),#\(plane),.T.)"))
        }

        let shell = w.add("CLOSED_SHELL('',(\(faceIds.map { "#\($0)" }.joined(separator: ","))))")
        return w.add("MANIFOLD_SOLID_BREP('\(ExportUtil.stepString(name))',#\(shell))")
    }

    private static func header(name: String) -> String {
        """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION((''),'2;1');
        FILE_NAME('\(ExportUtil.stepString(name))','\(ExportUtil.isoTimestamp)',(''),(''),'GrasshopperSwift','','');
        FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
        ENDSEC;

        """
    }
}
