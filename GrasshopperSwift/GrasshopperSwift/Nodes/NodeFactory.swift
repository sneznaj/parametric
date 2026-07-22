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
        case .point3D:
            return ([i("X", .number, .number(0)), i("Y", .number, .number(0)), i("Z", .number, .number(0))],
                    [o("Pt", .vector3)])

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
                     i("Color", .color, .color(.teal)),
                     i("Rough", .number, .number(0.35)),
                     i("Metal", .number, .number(0.0)),
                     i("Coat", .number, .number(0.08)),   // clearcoat for photoreal lacquers/plastics
                     i("Bump", .number, .number(0.18))], [])  // normal/bump strength for surface detail
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

        // Geometry – 2D
        case .geoPoint:
            return ([i("X", .number, .number(0)), i("Y", .number, .number(0)), i("Z", .number, .number(0))],
                    [o("Geo", .geometry)])
        case .geoLine:
            return ([i("A", .vector3), i("B", .vector3)], [o("Geo", .geometry)])
        case .geoCircle:
            return ([i("Center", .vector3), i("Radius", .number, .number(5)), i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoPolygon:
            return ([i("Center", .vector3), i("Radius", .number, .number(5)), i("Sides", .number, .number(6)),
                     i("Mat", .material)],
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
                     i("Height", .number, .number(5)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoEllipse:
            return ([i("Center", .vector3),
                     i("Rx", .number, .number(8)),
                     i("Ry", .number, .number(4)),
                     i("Mat", .material)],
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
            return ([i("A", .geometry),
                     i("B", .geometry),
                     i("Samples", .number, .number(24)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        // Geometry – 3D
        case .geoSphere:
            return ([i("Center", .vector3), i("Radius", .number, .number(5)), i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoBox:
            return ([i("Center", .vector3),
                     i("Width",  .number, .number(10)),
                     i("Height", .number, .number(10)),
                     i("Depth",  .number, .number(10)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoCylinder:
            return ([i("Center", .vector3),
                     i("Radius", .number, .number(5)),
                     i("Height", .number, .number(10)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoCone:
            return ([i("Base",   .vector3),
                     i("Radius", .number, .number(5)),
                     i("Height", .number, .number(10)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        case .geoTorus:
            return ([i("Center", .vector3),
                     i("MajorR", .number, .number(8)),
                     i("MinorR", .number, .number(2)),
                     i("Mat", .material)],
                    [o("Geo", .geometry)])
        // Material
        case .material:
            return ([i("R",       .number, .number(0.72)),
                     i("G",       .number, .number(0.72)),
                     i("B",       .number, .number(0.78)),
                     i("Rough",   .number, .number(0.35)),
                     i("Metal",   .number, .number(0.0)),
                     i("Spec",    .number, .number(0.55)),
                     i("Coat",    .number, .number(0.10)),
                     i("Bump",    .number, .number(0.22)),
                     i("Scale",   .number, .number(1.0)),
                     i("Var",     .number, .number(0.16)),
                     i("Aniso",   .number, .number(0.0)),
                     i("Type",    .text, .text("plastic")),
                     i("Finish",  .text, .text("satin")),
                     i("Pattern", .text, .text("smooth"))],
                    [o("Mat", .material)])
        case .materialABSPlastic,
             .materialAnodizedAluminum,
             .materialBrushedStainless,
             .materialBeadBlastedSteel,
             .materialChrome:
            return ([], [o("Mat", .material)])
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
        }
    }
}
