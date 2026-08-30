import Foundation
import SwiftUI

enum NodeFactory {
    static func make(_ kind: NodeKind, at position: CGPoint) -> Node {
        let (inputs, outputs) = ports(for: kind)
        return Node(kind: kind, position: position, inputs: inputs, outputs: outputs)
    }

    private static func i(_ name: String, _ type: PortType, _ default_: PortValue? = nil) -> Port {
        Port(name: name, type: type, isInput: true, value: default_)
    }
    private static func o(_ name: String, _ type: PortType) -> Port {
        Port(name: name, type: type, isInput: false)
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    static func ports(for kind: NodeKind) -> (inputs: [Port], outputs: [Port]) {
        switch kind {
        // Params
        case .numberSlider:
            return ([], [o("N", .number)])
        case .numberInput:
            return ([], [o("N", .number)])
        case .booleanToggle:
            return ([], [o("B", .boolean)])
        case .textInput:
            return ([], [o("T", .text)])
        case .colorPicker:
            return ([], [o("C", .color)])
        case .point2D:
            return ([i("X", .number, .number(0)), i("Y", .number, .number(0))],
                    [o("Pt", .vector2)])

        // Math
        case .add:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .number)])
        case .subtract:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .number)])
        case .multiply:
            return ([i("A", .number, .number(1)), i("B", .number, .number(1))], [o("R", .number)])
        case .divide:
            return ([i("A", .number, .number(1)), i("B", .number, .number(1))], [o("R", .number)])
        case .modulo:
            return ([i("A", .number, .number(0)), i("B", .number, .number(1))], [o("R", .number)])
        case .power:
            return ([i("Base", .number, .number(2)), i("Exp", .number, .number(2))], [o("R", .number)])
        case .absolute:
            return ([i("A", .number, .number(0))], [o("R", .number)])
        case .negate:
            return ([i("A", .number, .number(0))], [o("R", .number)])

        // Logic
        case .logicAnd:
            return ([i("A", .boolean, .boolean(true)), i("B", .boolean, .boolean(true))], [o("R", .boolean)])
        case .logicOr:
            return ([i("A", .boolean, .boolean(false)), i("B", .boolean, .boolean(false))], [o("R", .boolean)])
        case .logicNot:
            return ([i("A", .boolean, .boolean(true))], [o("R", .boolean)])
        case .greaterThan:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .boolean)])
        case .lessThan:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .boolean)])
        case .equality:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .boolean)])

        // Text
        case .concatenate:
            return ([i("A", .text, .text("")), i("B", .text, .text(""))], [o("R", .text)])
        case .textLength:
            return ([i("T", .text, .text(""))], [o("N", .number)])
        case .uppercase:
            return ([i("T", .text, .text(""))], [o("R", .text)])
        case .lowercase:
            return ([i("T", .text, .text(""))], [o("R", .text)])

        // Vector
        case .constructPoint:
            return ([i("X", .number, .number(0)), i("Y", .number, .number(0)), i("Z", .number, .number(0))],
                    [o("Pt", .vector3)])
        case .deconstruct:
            return ([i("Pt", .vector3)], [o("X", .number), o("Y", .number), o("Z", .number)])
        case .distance:
            return ([i("A", .vector3), i("B", .vector3)], [o("D", .number)])
        case .vectorAdd:
            return ([i("A", .vector3), i("B", .vector3)], [o("R", .vector3)])
        case .vectorScale:
            return ([i("V", .vector3), i("F", .number, .number(1))], [o("R", .vector3)])

        // Utility
        case .output:
            return ([i("Geo", .geometry),
                     i("Mat", .material),
                     i("Env", .renderConfig)], [])  // Mat applied uniformly to every connected Geo input; Env drives lighting/tone mapping
        case .remap:
            return ([i("V", .number, .number(0)),
                     i("Low", .number, .number(0)),
                     i("High", .number, .number(1)),
                     i("→Low", .number, .number(0)),
                     i("→High", .number, .number(1))],
                    [o("R", .number)])
        case .clamp:
            return ([i("V", .number, .number(0)), i("Low", .number, .number(0)), i("High", .number, .number(1))],
                    [o("R", .number)])
        case .lerp:
            return ([i("A", .number, .number(0)), i("B", .number, .number(1)), i("T", .number, .number(0.5))],
                    [o("R", .number)])
        case .mergeGeometry:
            return ([i("A", .geometry), i("B", .geometry)], [o("Geo", .geometry)])

        // Geometry – 2D
        case .geoPoint:
            return ([i("X", .number, .number(0)), i("Y", .number, .number(0)), i("Z", .number, .number(0))],
                    [o("Geo", .geometry)])
        case .geoLine:
            return ([i("A", .vector3), i("B", .vector3)], [o("Geo", .geometry)])
        case .geoCircle:
            return ([i("Center", .vector3), i("Radius", .number, .number(5))],
                    [o("Geo", .geometry)])
        case .geoPolygon:
            return ([i("Center", .vector3), i("Radius", .number, .number(5)), i("Sides", .number, .number(6))],
                    [o("Geo", .geometry)])
        case .geoGrid:
            return ([i("Width",  .number, .number(10)),
                     i("Height", .number, .number(10)),
                     i("Cols",   .number, .number(5)),
                     i("Rows",   .number, .number(5))],
                    [o("Geo", .geometry)])
        case .geoRectangle:
            return ([i("Center", .vector3),
                     i("Width",  .number, .number(10)),
                     i("Height", .number, .number(5))],
                    [o("Geo", .geometry)])
        case .geoEllipse:
            return ([i("Center", .vector3),
                     i("Rx", .number, .number(8)),
                     i("Ry", .number, .number(4))],
                    [o("Geo", .geometry)])
        case .geoArc:
            return ([i("Center", .vector3),
                     i("Radius", .number, .number(5)),
                     i("Start°", .number, .number(0)),
                     i("End°",   .number, .number(180))],
                    [o("Geo", .geometry)])
        case .geoBezier:
            return ([i("P0", .vector3),
                     i("P1", .vector3),
                     i("P2", .vector3),
                     i("P3", .vector3)],
                    [o("Geo", .geometry)])
        case .geoLoftSurface:
            return ([i("Curves", .geometry),
                     i("Samples", .number, .number(24)),
                     i("Closed", .boolean, .boolean(false))],
                    [o("Geo", .geometry)])
        case .geoBlendArc:
            return ([i("Pt₁", .vector3),
                     i("Line₁", .geometry),
                     i("Pt₂", .vector3),
                     i("Line₂", .geometry),
                     i("Segments", .number, .number(64))],
                    [o("Geo", .geometry)])
        // 2D Shapes
        case .shape2DPoint:
            return ([i("X", .number, .number(0)),
                     i("Y", .number, .number(0)),
                     i("Thick", .number, .number(2)),
                     i("Color", .color, .color(.white))],
                    [o("Geo", .geometry)])
        case .shape2DLine:
            return ([i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("BX", .number, .number(10)),
                     i("BY", .number, .number(10)),
                     i("Thick", .number, .number(2)),
                     i("Color", .color, .color(.white))],
                    [o("Geo", .geometry)])
        case .shape2DSquare:
            return ([i("CX", .number, .number(0)),
                     i("CY", .number, .number(0)),
                     i("Size", .number, .number(10)),
                     i("Thick", .number, .number(2)),
                     i("Stroke", .color, .color(.white)),
                     i("Fill", .color, .color(.white)),
                     i("FillOn", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .shape2DEllipse:
            return ([i("CX", .number, .number(0)),
                     i("CY", .number, .number(0)),
                     i("Rx", .number, .number(8)),
                     i("Ry", .number, .number(5)),
                     i("Thick", .number, .number(2)),
                     i("Stroke", .color, .color(.white)),
                     i("Fill", .color, .color(.white)),
                     i("FillOn", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .shape2DRectangle:
            return ([i("CX", .number, .number(0)),
                     i("CY", .number, .number(0)),
                     i("Width",  .number, .number(10)),
                     i("Height", .number, .number(6)),
                     i("Thick", .number, .number(2)),
                     i("Stroke", .color, .color(.white)),
                     i("Fill", .color, .color(.white)),
                     i("FillOn", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .shape2DRectangleCorners:
            return ([i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("BX", .number, .number(10)),
                     i("BY", .number, .number(6)),
                     i("Thick", .number, .number(2)),
                     i("Stroke", .color, .color(.white)),
                     i("Fill", .color, .color(.white)),
                     i("FillOn", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .shape2DSemicircle:
            return ([i("P1X", .number, .number(0)),
                     i("P1Y", .number, .number(0)),
                     i("Line₁", .geometry),
                     i("P2X", .number, .number(10)),
                     i("P2Y", .number, .number(0)),
                     i("Line₂", .geometry),
                     i("Thick", .number, .number(2)),
                     i("Color", .color, .color(.white))],
                    [o("Geo", .geometry)])
        // Geometry – 3D
        case .geoSphere:
            return ([i("Center", .vector3), i("Radius", .number, .number(5))],
                    [o("Geo", .geometry)])
        case .geoBox:
            return ([i("Center", .vector3),
                     i("Width",  .number, .number(10)),
                     i("Height", .number, .number(10)),
                     i("Depth",  .number, .number(10))],
                    [o("Geo", .geometry)])
        case .geoCylinder:
            return ([i("Center", .vector3),
                     i("Radius", .number, .number(5)),
                     i("Height", .number, .number(10))],
                    [o("Geo", .geometry)])
        case .geoCone:
            return ([i("Base",   .vector3),
                     i("Radius", .number, .number(5)),
                     i("Height", .number, .number(10))],
                    [o("Geo", .geometry)])
        case .geoTorus:
            return ([i("Center", .vector3),
                     i("MajorR", .number, .number(8)),
                     i("MinorR", .number, .number(2))],
                    [o("Geo", .geometry)])
        // Material
        case .material:
            // Rough/Metal/Spec/Coat/Bump/Var/Aniso all accept a plain
            // 0...100 range here (matching a fresh Number Slider's default
            // domain) and are rescaled to the internal 0...1 factor in
            // NodeEvaluator — so wiring an out-of-the-box slider straight in
            // uses its whole drag range instead of clamping flat past ~1%.
            return ([i("Color",    .color, .color(Color(red: 0.72, green: 0.72, blue: 0.78))),
                     i("Rough",   .number, .number(35)),
                     i("Metal",   .number, .number(0)),
                     i("Spec",    .number, .number(55)),
                     i("Coat",    .number, .number(10)),
                     i("Bump",    .number, .number(22)),
                     i("Scale",   .number, .number(1.0)),
                     i("Var",     .number, .number(16)),
                     i("Aniso",   .number, .number(0)),
                     i("Type",    .text, .text("plastic")),
                     i("Finish",  .text, .text("satin")),
                     i("Pattern", .text, .text("smooth")),
                     // Sheen: a cloth/fabric fuzz layer stacked on top of the
                     // metallic-roughness BRDF above (see studio_pbr.mat).
                     // Black (the default) is an exact no-op, so existing
                     // graphs built before this input existed keep rendering
                     // identically.
                     i("Sheen",      .color, .color(.black)),
                     i("Sheen Rough", .number, .number(30)),
                     // Transmission/IOR: dielectric glass/liquid (Ultra
                     // Realistic path tracer only — no-op in Filament today).
                     // Transmission is a plain 0...100 percent like the other
                     // sliders above; IOR is 0...200 rescaled to 1.0...3.0 in
                     // NodeEvaluator since it needs a >1 range.
                     i("Transmission", .number, .number(0)),
                     i("IOR",          .number, .number(50)),
                     // Emission: self-illumination (Ultra Realistic only —
                     // makes the surface an area light for the path tracer's
                     // light tree). Zero strength is an exact no-op.
                     i("Emission",          .color, .color(.black)),
                     i("Emission Strength", .number, .number(0))],
                    [o("Mat", .material)])
        case .materialABSPlastic,
             .materialAnodizedAluminum,
             .materialBrushedStainless,
             .materialBeadBlastedSteel,
             .materialChrome,
             .materialVelvet,
             .materialWax:
            return ([], [o("Mat", .material)])
        // Lighting / Scene Environment
        case .sceneLighting:
            // Contrast/Saturation accept a plain 0...100 range (50 = neutral,
            // matching a fresh Number Slider's default domain) and are
            // rescaled to the internal -1...1 factor in NodeEvaluator, same
            // reasoning as the Material node's R/G/B/Rough/etc. inputs.
            return ([i("Sun X",    .number, .number(-0.55)),
                     i("Sun Y",    .number, .number(-0.72)),
                     i("Sun Z",    .number, .number(0.41)),
                     i("Sun Color", .color, .color(Color(red: 1.0, green: 0.95, blue: 0.88))),
                     i("Sun Lux",  .number, .number(80_000)),
                     i("Exposure", .number, .number(0)),
                     i("Contrast", .number, .number(50)),
                     i("Saturation", .number, .number(50)),
                     i("White K",  .number, .number(6500)),
                     i("Tone Map", .text, .text("aces"))],
                    [o("Env", .renderConfig)])
        case .pointLight:
            // Env chains in an upstream Scene Lighting / Point Light node so
            // multiple lights can be stacked by wiring them one after
            // another — same pattern as the sun's single Env slot, just
            // extended rather than replaced.
            return ([i("Position", .vector3, .vector3(x: 0, y: 0, z: 5)),
                     i("Color", .color, .color(.white)),
                     i("Strength", .number, .number(1000)),
                     i("Env", .renderConfig)],
                    [o("Env", .renderConfig)])
        case .objectLight:
            // Same Color/Strength/Env-chaining shape as Point Light above,
            // but takes a Geo input instead of a Position — whatever shape
            // is wired in becomes a self-illuminating area light (Ultra
            // Realistic path tracer only; no-op in the Filament "Realistic"
            // view, same as Volumetric Fog below).
            return ([i("Geo", .geometry),
                     i("Color", .color, .color(.white)),
                     i("Strength", .number, .number(20)),
                     i("Env", .renderConfig)],
                    [o("Env", .renderConfig)])
        case .volumetricFog:
            // Ultra Realistic (path tracer) only — a no-op for the Filament
            // "Realistic" view. Chains through Env like Point Light/Scene
            // Lighting above; Density/Anisotropy/Height Falloff accept a
            // plain 0...100 range and are rescaled in NodeEvaluator.
            return ([i("Enabled",  .boolean, .boolean(true)),
                     i("Density",  .number, .number(20)),
                     i("Color",    .color, .color(.white)),
                     i("Anisotropy", .number, .number(50)),
                     i("Height Falloff", .number, .number(0)),
                     i("Env", .renderConfig)],
                    [o("Env", .renderConfig)])
        case .geoTranslate:
            return ([i("Geo", .geometry),
                     i("TX", .number, .number(0)),
                     i("TY", .number, .number(0)),
                     i("TZ", .number, .number(0))],
                    [o("Geo", .geometry)])
        case .geoRotate:
            return ([i("Geo", .geometry),
                     i("Angle°", .number, .number(45)),
                     i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("AZ", .number, .number(1))],
                    [o("Geo", .geometry)])
        case .geoScale:
            return ([i("Geo", .geometry), i("Factor", .number, .number(2))], [o("Geo", .geometry)])

        // Vector – Planes
        case .constructPlane:
            return ([i("Origin", .vector3, .vector3(x: 0, y: 0, z: 0)),
                     i("Normal", .vector3, .vector3(x: 0, y: 0, z: 1)),
                     i("XAxis", .vector3, .vector3(x: 1, y: 0, z: 0))],
                    [o("Pl", .plane)])
        case .deconstructPlane:
            return ([i("Pl", .plane)], [o("Origin", .vector3), o("Normal", .vector3), o("XAxis", .vector3)])
        case .planeXY:
            return ([], [o("Pl", .plane)])
        case .planeYZ:
            return ([], [o("Pl", .plane)])
        case .planeZX:
            return ([], [o("Pl", .plane)])

        // Transform
        case .geoScaleNU:
            return ([i("Geo", .geometry),
                     i("Fx", .number, .number(1)),
                     i("Fy", .number, .number(1)),
                     i("Fz", .number, .number(1))],
                    [o("Geo", .geometry)])
        case .geoMirror:
            return ([i("Geo", .geometry), i("Plane", .plane)], [o("Geo", .geometry)])
        case .geoArrayLinear:
            return ([i("Geo", .geometry),
                     i("DX", .number, .number(1)),
                     i("DY", .number, .number(0)),
                     i("DZ", .number, .number(0)),
                     i("Count", .number, .number(5)),
                     i("Spacing", .number, .number(5))],
                    [o("Geo", .geometry)])
        case .geoArrayPolar:
            return ([i("Geo", .geometry),
                     i("CX", .number, .number(0)),
                     i("CY", .number, .number(0)),
                     i("CZ", .number, .number(0)),
                     i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("AZ", .number, .number(1)),
                     i("Count", .number, .number(8)),
                     i("Angle°", .number, .number(360))],
                    [o("Geo", .geometry)])
        case .geoOrient:
            return ([i("Geo", .geometry), i("From", .plane), i("To", .plane)], [o("Geo", .geometry)])

        // Curve
        case .curveDivide:
            return ([i("Curve", .geometry), i("Count", .number, .number(10))], [o("Pts", .geometry)])
        case .curveLength:
            return ([i("Curve", .geometry)], [o("L", .number)])
        case .curvePointAt:
            return ([i("Curve", .geometry), i("T", .number, .number(0.5))], [o("Pt", .vector3)])
        case .curveEndPoints:
            return ([i("Curve", .geometry)], [o("Start", .vector3), o("End", .vector3)])
        case .curveExtend:
            return ([i("Curve", .geometry), i("Start", .number, .number(0)), i("End", .number, .number(0))],
                    [o("Geo", .geometry)])
        case .curveOffset:
            return ([i("Curve", .geometry), i("Distance", .number, .number(1))], [o("Geo", .geometry)])
        case .curveFillet:
            return ([i("Curve", .geometry), i("Radius", .number, .number(1))], [o("Geo", .geometry)])
        case .curveInterpolate:
            return ([i("Pts", .geometry), i("Degree", .number, .number(3)), i("Closed", .boolean, .boolean(false))],
                    [o("Geo", .geometry)])
        case .curveClosestPoint:
            return ([i("Curve", .geometry), i("Pt", .vector3)],
                    [o("Point", .vector3), o("T", .number), o("Distance", .number)])
        case .curveCurveIntersect:
            return ([i("A", .geometry), i("B", .geometry)], [o("Pts", .geometry)])

        // Surface
        case .surfaceExtrude:
            return ([i("Profile", .geometry),
                     i("DX", .number, .number(0)),
                     i("DY", .number, .number(0)),
                     i("DZ", .number, .number(5)),
                     i("Cap", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .surfaceExtrudePoint:
            return ([i("Profile", .geometry), i("Apex", .vector3), i("Cap", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])
        case .surfaceRevolve:
            return ([i("Profile", .geometry),
                     i("AxisOrigin", .vector3),
                     i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("AZ", .number, .number(1)),
                     i("Angle°", .number, .number(360)),
                     i("Segments", .number, .number(32))],
                    [o("Geo", .geometry)])
        case .surfaceSweep1:
            return ([i("Profile", .geometry), i("Rail", .geometry)], [o("Geo", .geometry)])
        case .surfaceBoundary:
            return ([i("Curve", .geometry)], [o("Geo", .geometry)])
        case .surfaceOffset:
            return ([i("Geo", .geometry), i("Distance", .number, .number(1))], [o("Geo", .geometry)])
        case .surfacePipe:
            return ([i("Rail", .geometry),
                     i("Radius", .number, .number(1)),
                     i("Segments", .number, .number(16)),
                     i("Cap", .boolean, .boolean(true))],
                    [o("Geo", .geometry)])

        // Solid
        case .solidUnion:
            return ([i("A", .geometry), i("B", .geometry)], [o("Geo", .geometry)])
        case .solidDifference:
            return ([i("A", .geometry), i("B", .geometry)], [o("Geo", .geometry)])
        case .solidIntersection:
            return ([i("A", .geometry), i("B", .geometry)], [o("Geo", .geometry)])
        case .solidCapHoles:
            return ([i("Geo", .geometry)], [o("Geo", .geometry)])
        case .solidBoundingBox:
            return ([i("Geo", .geometry)],
                    [o("Box", .geometry), o("Width", .number), o("Height", .number), o("Depth", .number)])
        case .solidVolume:
            return ([i("Geo", .geometry)], [o("V", .number)])
        case .solidCentroid:
            return ([i("Geo", .geometry)], [o("Pt", .vector3)])

        // Intersect
        case .meshPlaneSection:
            return ([i("Geo", .geometry), i("Plane", .plane)], [o("Geo", .geometry)])
        case .lineLineIntersect:
            return ([i("A", .geometry), i("B", .geometry)], [o("Pt", .vector3), o("Success", .boolean)])
        case .planePlaneIntersect:
            return ([i("A", .plane), i("B", .plane)], [o("Line", .geometry), o("Success", .boolean)])
        case .planeLineIntersect:
            return ([i("Plane", .plane), i("Line", .geometry)], [o("Pt", .vector3), o("Success", .boolean)])
        case .pointPlaneDistance:
            return ([i("Pt", .vector3), i("Plane", .plane)], [o("D", .number)])

        // MARK: Vector (additions)
        case .vectorTwoPt:
            return ([i("A", .vector3), i("B", .vector3, .vector3(x: 1, y: 0, z: 0))], [o("V", .vector3)])
        case .vectorUnitize:
            return ([i("V", .vector3, .vector3(x: 1, y: 0, z: 0))], [o("V", .vector3)])
        case .vectorLength:
            return ([i("V", .vector3)], [o("L", .number)])
        case .vectorReverse:
            return ([i("V", .vector3)], [o("V", .vector3)])
        case .vectorCrossProduct:
            return ([i("A", .vector3, .vector3(x: 1, y: 0, z: 0)), i("B", .vector3, .vector3(x: 0, y: 1, z: 0))],
                    [o("V", .vector3)])
        case .vectorDotProduct:
            return ([i("A", .vector3, .vector3(x: 1, y: 0, z: 0)), i("B", .vector3, .vector3(x: 0, y: 1, z: 0))],
                    [o("R", .number)])
        case .vectorRotate:
            return ([i("V", .vector3, .vector3(x: 1, y: 0, z: 0)),
                     i("Angle°", .number, .number(90)),
                     i("Axis", .vector3, .vector3(x: 0, y: 0, z: 1))],
                    [o("V", .vector3)])
        case .vectorAngle:
            return ([i("A", .vector3, .vector3(x: 1, y: 0, z: 0)), i("B", .vector3, .vector3(x: 0, y: 1, z: 0))],
                    [o("Angle°", .number)])

        // MARK: Point (additions)
        case .pointOnPlane:
            return ([i("Pl", .plane), i("U", .number, .number(0)), i("V", .number, .number(0))], [o("Pt", .vector3)])
        case .pointPolar:
            return ([i("Pl", .plane), i("Angle°", .number, .number(0)), i("Radius", .number, .number(5))],
                    [o("Pt", .vector3)])
        case .pointCylindrical:
            return ([i("Pl", .plane),
                     i("Angle°", .number, .number(0)),
                     i("Radius", .number, .number(5)),
                     i("Z", .number, .number(0))],
                    [o("Pt", .vector3)])
        case .constructPointPolar:
            return ([i("Origin", .vector3, .vector3(x: 0, y: 0, z: 0)),
                     i("Angle°", .number, .number(0)),
                     i("Distance", .number, .number(5))],
                    [o("Pt", .vector3)])
        case .projectPointToPlane:
            return ([i("Pt", .vector3), i("Pl", .plane)], [o("Pt", .vector3)])
        case .populate3D:
            return ([i("Center", .vector3),
                     i("SizeX", .number, .number(10)),
                     i("SizeY", .number, .number(10)),
                     i("SizeZ", .number, .number(10)),
                     i("Count", .number, .number(20)),
                     i("Seed", .number, .number(0))],
                    [o("Pts", .geometry)])

        // MARK: Plane (additions)
        case .planeThreePt:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 1, y: 0, z: 0)),
                     i("C", .vector3, .vector3(x: 0, y: 1, z: 0))],
                    [o("Pl", .plane)])
        case .planeFlip:
            return ([i("Pl", .plane)], [o("Pl", .plane)])

        // MARK: Transform (additions)
        case .geoProject:
            return ([i("Geo", .geometry), i("Plane", .plane)], [o("Geo", .geometry)])
        case .geoTwist:
            return ([i("Geo", .geometry),
                     i("AxisOrigin", .vector3),
                     i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("AZ", .number, .number(1)),
                     i("Angle°", .number, .number(90))],
                    [o("Geo", .geometry)])
        case .geoTaper:
            return ([i("Geo", .geometry),
                     i("AxisOrigin", .vector3),
                     i("AX", .number, .number(0)),
                     i("AY", .number, .number(0)),
                     i("AZ", .number, .number(1)),
                     i("Start", .number, .number(1)),
                     i("End", .number, .number(0.3))],
                    [o("Geo", .geometry)])

        // MARK: Geometry primitives (additions)
        case .geoLineSDL:
            return ([i("Start", .vector3),
                     i("Direction", .vector3, .vector3(x: 1, y: 0, z: 0)),
                     i("Length", .number, .number(10))],
                    [o("Geo", .geometry)])
        case .geoCircleThreePt:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 5, y: 0, z: 0)),
                     i("C", .vector3, .vector3(x: 0, y: 5, z: 0))],
                    [o("Geo", .geometry)])
        case .geoArcThreePt:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 5, y: 5, z: 0)),
                     i("C", .vector3, .vector3(x: 10, y: 0, z: 0))],
                    [o("Geo", .geometry)])
        case .geoPolyline:
            return ([i("Pts", .geometry)], [o("Geo", .geometry)])

        // MARK: Curve (additions)
        case .curveExplode:
            return ([i("Curve", .geometry)], [o("Segments", .geometry)])
        case .curveJoin:
            return ([i("Curves", .geometry)], [o("Geo", .geometry)])
        case .curveFrame:
            return ([i("Curve", .geometry), i("T", .number, .number(0.5))], [o("Pl", .plane)])
        case .curveArea:
            return ([i("Curve", .geometry)], [o("Area", .number), o("Centroid", .vector3)])

        // MARK: Surface (additions)
        case .surfaceFourPoint:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 10, y: 0, z: 0)),
                     i("C", .vector3, .vector3(x: 10, y: 10, z: 0)),
                     i("D", .vector3, .vector3(x: 0, y: 10, z: 0))],
                    [o("Geo", .geometry)])
        case .surfaceArea:
            return ([i("Geo", .geometry)], [o("Area", .number)])
        case .meshClosestPoint:
            return ([i("Mesh", .geometry), i("Pt", .vector3)], [o("Point", .vector3), o("Distance", .number)])

        // MARK: Curve – Spline (additions)
        case .curveNurbsCurve:
            return ([i("Pts", .geometry), i("Degree", .number, .number(3)), i("Closed", .boolean, .boolean(false))],
                    [o("Geo", .geometry)])
        case .curveControlPoints:
            return ([i("Curve", .geometry)], [o("Pts", .geometry), o("Count", .number)])
        case .curveRebuild:
            return ([i("Curve", .geometry), i("Count", .number, .number(10)), i("Degree", .number, .number(3))],
                    [o("Geo", .geometry)])

        // MARK: Solid / Mesh (additions)
        case .deconstructMesh:
            return ([i("Mesh", .geometry)], [o("Verts", .number), o("Faces", .number)])
        case .meshArea:
            return ([i("Mesh", .geometry)], [o("Area", .number)])
        case .joinMeshes:
            return ([i("A", .geometry), i("B", .geometry)], [o("Geo", .geometry)])
        case .weldMesh:
            return ([i("Mesh", .geometry), i("Tolerance", .number, .number(0.001))], [o("Geo", .geometry)])
        case .deconstructBox:
            return ([i("Geo", .geometry)], [o("Min", .vector3), o("Max", .vector3), o("Center", .vector3)])

        // MARK: Geometry – more primitives (additions)
        case .geoBoxTwoPt:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 10, y: 10, z: 10))],
                    [o("Geo", .geometry)])
        case .geoBoxOriented:
            return ([i("Pl", .plane),
                     i("SizeX", .number, .number(10)),
                     i("SizeY", .number, .number(10)),
                     i("SizeZ", .number, .number(10))],
                    [o("Geo", .geometry)])
        case .geoCylinderTwoPt:
            return ([i("A", .vector3),
                     i("B", .vector3, .vector3(x: 0, y: 0, z: 10)),
                     i("Radius", .number, .number(3))],
                    [o("Geo", .geometry)])
        case .geoPyramid:
            return ([i("Center", .vector3),
                     i("Radius", .number, .number(5)),
                     i("Sides", .number, .number(4)),
                     i("Height", .number, .number(10))],
                    [o("Geo", .geometry)])

        // MARK: Plane (additions)
        case .planeBetweenLines:
            return ([i("A", .geometry), i("B", .geometry)], [o("Pl", .plane)])

        // MARK: Math – trig / rounding / constants (additions)
        case .sine, .cosine, .tangent:
            return ([i("Angle°", .number, .number(0))], [o("R", .number)])
        case .arcsine, .arccosine:
            return ([i("A", .number, .number(0))], [o("Angle°", .number)])
        case .arctangent2:
            return ([i("Y", .number, .number(0)), i("X", .number, .number(1))], [o("Angle°", .number)])
        case .squareRoot:
            return ([i("A", .number, .number(4))], [o("R", .number)])
        case .mathRound, .mathFloor, .mathCeiling, .mathTruncate:
            return ([i("A", .number, .number(0))], [o("R", .number)])
        case .mathMin, .mathMax:
            return ([i("A", .number, .number(0)), i("B", .number, .number(0))], [o("R", .number)])
        case .degreesToRadians:
            return ([i("Deg", .number, .number(0))], [o("Rad", .number)])
        case .radiansToDegrees:
            return ([i("Rad", .number, .number(0))], [o("Deg", .number)])
        case .constantPi:
            return ([], [o("π", .number)])
        case .mathLog:
            return ([i("A", .number, .number(1)), i("Base", .number, .number(10))], [o("R", .number)])
        case .mathExp:
            return ([i("A", .number, .number(1))], [o("R", .number)])
        case .mathExpression:
            // Inputs are dynamic — NodeGraph.syncExpressionPorts adds one
            // number input per variable letter found in the formula text.
            return ([], [o("R", .number)])

        // MARK: Logic (additions)
        case .logicXor:
            return ([i("A", .boolean, .boolean(true)), i("B", .boolean, .boolean(false))], [o("R", .boolean)])

        // MARK: Vector (additions)
        case .vectorSetLength:
            return ([i("V", .vector3, .vector3(x: 1, y: 0, z: 0)), i("Length", .number, .number(1))], [o("V", .vector3)])
        case .unitX:
            return ([], [o("V", .vector3)])
        case .unitY:
            return ([], [o("V", .vector3)])
        case .unitZ:
            return ([], [o("V", .vector3)])

        // MARK: Params – Color (additions)
        case .constructColor:
            return ([i("R", .number, .number(0.7)),
                     i("G", .number, .number(0.7)),
                     i("B", .number, .number(0.7)),
                     i("A", .number, .number(1))],
                    [o("C", .color)])
        case .deconstructColor:
            return ([i("C", .color)], [o("R", .number), o("G", .number), o("B", .number), o("A", .number)])
        case .constructColorRGB:
            return ([i("R", .number, .number(0.7)),
                     i("G", .number, .number(0.7)),
                     i("B", .number, .number(0.7))],
                    [o("C", .color)])
        case .constructColorPicker:
            return ([], [o("C", .color)])

        // MARK: Curve (additions)
        case .curveDivideLength:
            return ([i("Curve", .geometry), i("Length", .number, .number(1))], [o("Pts", .geometry)])
        case .evaluateCurve:
            return ([i("Curve", .geometry), i("T", .number, .number(0.5))], [o("Point", .vector3), o("Tangent", .vector3)])
        case .curveCurvature:
            return ([i("Curve", .geometry), i("T", .number, .number(0.5))], [o("Radius", .number), o("Center", .vector3)])
        case .isCurveClosed:
            return ([i("Curve", .geometry)], [o("Closed", .boolean)])

        // MARK: Solid / Mesh (additions)
        case .isMeshClosed:
            return ([i("Mesh", .geometry)], [o("Closed", .boolean)])
        case .flipMesh:
            return ([i("Mesh", .geometry)], [o("Geo", .geometry)])

        // MARK: Intersect (additions)
        case .lineSphereIntersect:
            return ([i("Line", .geometry), i("Center", .vector3), i("Radius", .number, .number(5))],
                    [o("A", .vector3), o("B", .vector3), o("Success", .boolean)])
        case .spherePlaneIntersect:
            return ([i("Center", .vector3), i("Radius", .number, .number(5)), i("Plane", .plane)],
                    [o("Geo", .geometry), o("Success", .boolean)])
        case .pointInBox:
            return ([i("Pt", .vector3), i("Box", .geometry)], [o("Inside", .boolean)])
        }
    }
}
