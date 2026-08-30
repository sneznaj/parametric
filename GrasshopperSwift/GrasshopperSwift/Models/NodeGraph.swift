import Combine
import Foundation
import SwiftUI
import AppKit

final class CanvasViewport: ObservableObject {
    @Published var offset: CGSize = .zero
    @Published var scale: CGFloat = 1.0
    @Published var size: CGSize = .zero

    private var insertionStep: CGFloat = 0

    var visibleRect: CGRect {
        guard size.width > 0, size.height > 0, scale > 0 else {
            return CGRect(x: 80, y: 80, width: 480, height: 320)
        }

        return CGRect(
            x: -offset.width / scale,
            y: -offset.height / scale,
            width: size.width / scale,
            height: size.height / scale
        )
    }

    /// - Parameter anchorYFraction: where (0 = top, 1 = bottom of the visible
    ///   canvas) to place the node, so it lands next to the UI element that
    ///   triggered creation (e.g. the library row that was clicked). `nil`
    ///   falls back to vertically centering, as before.
    func nextNodePosition(nodeSize: CGSize, anchorYFraction: CGFloat? = nil) -> CGPoint {
        let visibleRect = visibleRect
        let padding: CGFloat = 24
        let maxX = max(visibleRect.minX + padding, visibleRect.maxX - nodeSize.width - padding)
        let maxY = max(visibleRect.minY + padding, visibleRect.maxY - nodeSize.height - padding)

        let baseX: CGFloat
        let baseY: CGFloat
        if let anchorYFraction {
            // Hug the edge of the canvas adjacent to the panel the button lives
            // in, at the same relative height as the button itself.
            baseX = visibleRect.minX + padding
            baseY = min(max(visibleRect.minY + padding, visibleRect.minY + anchorYFraction * visibleRect.height - nodeSize.height / 2), maxY)
        } else {
            baseX = min(max(visibleRect.minX + padding, visibleRect.midX - nodeSize.width / 2), maxX)
            baseY = min(max(visibleRect.minY + padding, visibleRect.midY - nodeSize.height / 2), maxY)
        }

        let step = min(28, max(16, min(visibleRect.width, visibleRect.height) * 0.06))
        let spanX = max(0, maxX - baseX)
        let spanY = max(0, maxY - baseY)
        let columns = max(1, Int(spanX / step) + 1)
        let rows = max(1, Int(spanY / step) + 1)
        let slotCount = max(1, columns * rows)
        let slot = Int(insertionStep) % slotCount
        let column = slot % columns
        let row = slot / columns

        insertionStep += 1

        return CGPoint(
            x: min(baseX + CGFloat(column) * step, maxX),
            y: min(baseY + CGFloat(row) * step, maxY)
        )
    }
}

// MARK: - Port

enum PortType: String, Codable, CaseIterable, Identifiable {
    case number, vector2, vector3, boolean, text, color, geometry, material, plane, renderConfig, any

    var id: String { rawValue }

    /// The color a user hasn't customized in Settings falls back to.
    /// Use `PortColorStore.shared.color(for:)` for the user-visible, possibly
    /// overridden color — this is only the built-in default.
    var defaultColor: Color {
        switch self {
        case .number:   return .orange
        case .vector2:  return .green
        case .vector3:  return .blue
        case .boolean:  return .red
        case .text:     return .purple
        case .color:    return .pink
        case .geometry: return .teal
        case .material: return .yellow
        case .plane:    return .cyan
        case .renderConfig: return .indigo
        case .any:      return .gray
        }
    }

    var displayName: String {
        switch self {
        case .number:   return "Number"
        case .vector2:  return "Vector2"
        case .vector3:  return "Vector3"
        case .boolean:  return "Boolean"
        case .text:     return "Text"
        case .color:    return "Color"
        case .geometry: return "Geometry"
        case .material: return "Material"
        case .plane:    return "Plane"
        case .renderConfig: return "Scene Env"
        case .any:      return "Any"
        }
    }
}

struct Port: Identifiable, Codable {
    let id: UUID
    let name: String
    let type: PortType
    let isInput: Bool
    var value: PortValue?

    init(id: UUID = UUID(), name: String, type: PortType, isInput: Bool, value: PortValue? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isInput = isInput
        self.value = value
    }
}

// MARK: - Port Value

enum PortValue: Codable {
    case number(Double)
    case vector2(CGPoint)
    case vector3(x: Double, y: Double, z: Double)
    case boolean(Bool)
    case text(String)
    case color(Color)
    case geometry([GeometricShape])
    case material(Material3D)
    case plane(origin: Point3D, normal: Point3D, xAxis: Point3D)
    case renderConfig(RenderConfig)

    var displayString: String {
        switch self {
        case .number(let v):        return String(format: "%.3g", v)
        case .vector2(let p):       return String(format: "(%.2g, %.2g)", p.x, p.y)
        case .vector3(let x, let y, let z): return String(format: "(%.2g, %.2g, %.2g)", x, y, z)
        case .boolean(let b):       return b ? "True" : "False"
        case .text(let s):          return s
        case .color:                return "Color"
        case .geometry(let shapes): return "\(shapes.count) shape\(shapes.count == 1 ? "" : "s")"
        case .material(let m):
            return "\(m.resolvedSurfaceType.rawValue) \(m.resolvedFinish.rawValue) r:\(String(format: "%.2g", m.roughness)) m:\(String(format: "%.2g", m.metalness))"
        case .plane(let o, let n, _):
            return String(format: "Pl (%.2g,%.2g,%.2g) n:(%.2g,%.2g,%.2g)", o.x, o.y, o.z, n.x, n.y, n.z)
        case .renderConfig:         return "Render Config"
        }
    }

    func asDouble() -> Double? {
        if case .number(let v) = self { return v }
        if case .boolean(let b) = self { return b ? 1 : 0 }
        return nil
    }

    func asColorComponents() -> (r: Double, g: Double, b: Double)? {
        guard case .color(let color) = self else { return nil }
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return (
            r: Double(nsColor.redComponent),
            g: Double(nsColor.greenComponent),
            b: Double(nsColor.blueComponent)
        )
    }

    func asColorComponentsRGBA() -> (r: Double, g: Double, b: Double, a: Double)? {
        guard case .color(let color) = self else { return nil }
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return (
            r: Double(nsColor.redComponent),
            g: Double(nsColor.greenComponent),
            b: Double(nsColor.blueComponent),
            a: Double(nsColor.alphaComponent)
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum ValueType: String, Codable {
        case number, vector2, vector3, boolean, text, color, geometry, material, plane, renderConfig
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let v):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(v, forKey: .value)
        case .vector2(let point):
            try container.encode(ValueType.vector2, forKey: .type)
            try container.encode(point, forKey: .value)
        case .vector3(let x, let y, let z):
            try container.encode(ValueType.vector3, forKey: .type)
            var nested = container.nestedUnkeyedContainer(forKey: .value)
            try nested.encode(x)
            try nested.encode(y)
            try nested.encode(z)
        case .boolean(let v):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(v, forKey: .value)
        case .text(let v):
            try container.encode(ValueType.text, forKey: .type)
            try container.encode(v, forKey: .value)
        case .color(let c):
            try container.encode(ValueType.color, forKey: .type)
            var nested = container.nestedUnkeyedContainer(forKey: .value)
            let nsColor = NSColor(c).usingColorSpace(.deviceRGB) ?? .white
            try nested.encode(Double(nsColor.redComponent))
            try nested.encode(Double(nsColor.greenComponent))
            try nested.encode(Double(nsColor.blueComponent))
            try nested.encode(Double(nsColor.alphaComponent))
        case .geometry(let shapes):
            try container.encode(ValueType.geometry, forKey: .type)
            try container.encode(shapes, forKey: .value)
        case .material(let mat):
            try container.encode(ValueType.material, forKey: .type)
            try container.encode(mat, forKey: .value)
        case .plane(let origin, let normal, let xAxis):
            try container.encode(ValueType.plane, forKey: .type)
            var nested = container.nestedUnkeyedContainer(forKey: .value)
            try nested.encode(origin)
            try nested.encode(normal)
            try nested.encode(xAxis)
        case .renderConfig(let config):
            try container.encode(ValueType.renderConfig, forKey: .type)
            try container.encode(config, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .number:
            let v = try container.decode(Double.self, forKey: .value)
            self = .number(v)
        case .vector2:
            let point = try container.decode(CGPoint.self, forKey: .value)
            self = .vector2(point)
        case .vector3:
            var nested = try container.nestedUnkeyedContainer(forKey: .value)
            let x = try nested.decode(Double.self)
            let y = try nested.decode(Double.self)
            let z = try nested.decode(Double.self)
            self = .vector3(x: x, y: y, z: z)
        case .boolean:
            let v = try container.decode(Bool.self, forKey: .value)
            self = .boolean(v)
        case .text:
            let v = try container.decode(String.self, forKey: .value)
            self = .text(v)
        case .color:
            var nested = try container.nestedUnkeyedContainer(forKey: .value)
            let r = try nested.decode(Double.self)
            let g = try nested.decode(Double.self)
            let b = try nested.decode(Double.self)
            let a = try nested.decode(Double.self)
            self = .color(Color(red: r, green: g, blue: b, opacity: a))
        case .geometry:
            let shapes = try container.decode([GeometricShape].self, forKey: .value)
            self = .geometry(shapes)
        case .material:
            let mat = try container.decode(Material3D.self, forKey: .value)
            self = .material(mat)
        case .plane:
            var nested = try container.nestedUnkeyedContainer(forKey: .value)
            let origin = try nested.decode(Point3D.self)
            let normal = try nested.decode(Point3D.self)
            let xAxis = try nested.decode(Point3D.self)
            self = .plane(origin: origin, normal: normal, xAxis: xAxis)
        case .renderConfig:
            let config = try container.decode(RenderConfig.self, forKey: .value)
            self = .renderConfig(config)
        }
    }
}

// MARK: - Connection

struct Connection: Identifiable, Codable {
    let id: UUID
    let fromNodeID: UUID
    let fromPortID: UUID
    let toNodeID: UUID
    let toPortID: UUID

    init(id: UUID = UUID(), fromNodeID: UUID, fromPortID: UUID, toNodeID: UUID, toPortID: UUID) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.fromPortID = fromPortID
        self.toNodeID = toNodeID
        self.toPortID = toPortID
    }
}

// MARK: - Node

class Node: Identifiable, ObservableObject {
    let id: UUID
    let kind: NodeKind
    @Published var position: CGPoint
    @Published var inputs: [Port]
    @Published var outputs: [Port]
    @Published var isSelected: Bool = false
    @Published var label: String
    // Slider configuration (only used by numberSlider nodes)
    @Published var sliderMin: Double = 0
    @Published var sliderMax: Double = 100
    @Published var sliderStep: Double = 0
    // Formula text (only used by .mathExpression nodes) — each distinct
    // letter it references becomes an input port; see MathExpression.
    @Published var expression: String = ""

    init(id: UUID = UUID(), kind: NodeKind, position: CGPoint, inputs: [Port], outputs: [Port], label: String? = nil) {
        self.id = id
        self.kind = kind
        self.position = position
        self.inputs = inputs
        self.outputs = outputs
        self.label = label ?? kind.defaultLabel
    }

    var title: String { kind.defaultLabel }

    static let width: CGFloat = 160
    static let headerHeight: CGFloat = 32
    static let portRowHeight: CGFloat = 24
    static let portRadius: CGFloat = 7

    var height: CGFloat {
        let rows = CGFloat(max(inputs.count, outputs.count))
        return Node.headerHeight + rows * Node.portRowHeight + 8
    }

    func inputPortPosition(index: Int, in graph: NodeGraph) -> CGPoint {
        let y = Node.headerHeight + CGFloat(index) * Node.portRowHeight + Node.portRowHeight / 2
        return CGPoint(x: position.x, y: position.y + y)
    }

    func outputPortPosition(index: Int, in graph: NodeGraph) -> CGPoint {
        let y = Node.headerHeight + CGFloat(index) * Node.portRowHeight + Node.portRowHeight / 2
        return CGPoint(x: position.x + Node.width, y: position.y + y)
    }
}

// MARK: - Node Kind

enum NodeKind: String, CaseIterable, Codable {
    // Params
    case numberSlider, numberInput, booleanToggle, textInput, colorPicker, point2D
    // Math
    case add, subtract, multiply, divide, modulo, power, absolute, negate
    // Logic
    case logicAnd, logicOr, logicNot, greaterThan, lessThan, equality
    // Text
    case concatenate, textLength, uppercase, lowercase
    // Vector
    case constructPoint, deconstruct, distance, vectorAdd, vectorScale
    // Utility
    case output, remap, clamp, lerp
    // Geometry – 2D
    case geoPoint, geoLine, geoCircle, geoPolygon, geoGrid
    case geoRectangle, geoEllipse, geoArc, geoBezier, geoLoftSurface, geoBlendArc
    // Geometry – 3D
    case geoSphere, geoBox, geoCylinder, geoCone, geoTorus
    // Transforms
    case geoTranslate, geoRotate, geoScale
    // Material
    case material, materialABSPlastic, materialAnodizedAluminum, materialBrushedStainless, materialBeadBlastedSteel, materialChrome, materialVelvet, materialWax
    // Lighting / Scene Environment
    case sceneLighting, pointLight, objectLight, volumetricFog
    // 2D Shapes
    case shape2DPoint, shape2DLine, shape2DSquare, shape2DEllipse
    case shape2DRectangle, shape2DRectangleCorners, shape2DSemicircle
    // Vector – Planes
    case constructPlane, deconstructPlane, planeXY, planeYZ, planeZX
    // Transform (additions; geoTranslate/geoRotate/geoScale above also live in this category)
    case geoScaleNU, geoMirror, geoArrayLinear, geoArrayPolar, geoOrient
    // Curve
    case curveDivide, curveLength, curvePointAt, curveEndPoints, curveExtend
    case curveOffset, curveFillet, curveInterpolate, curveClosestPoint, curveCurveIntersect
    // Surface (additions; geoLoftSurface above also lives in this category)
    case surfaceExtrude, surfaceExtrudePoint, surfaceRevolve, surfaceSweep1
    case surfaceBoundary, surfaceOffset, surfacePipe
    // Solid
    case solidUnion, solidDifference, solidIntersection, solidCapHoles
    case solidBoundingBox, solidVolume, solidCentroid
    // Intersect
    case meshPlaneSection, lineLineIntersect
    case planePlaneIntersect, planeLineIntersect, pointPlaneDistance
    // Vector (additions)
    case vectorTwoPt, vectorUnitize, vectorLength, vectorReverse
    case vectorCrossProduct, vectorDotProduct, vectorRotate, vectorAngle
    // Point (additions)
    case pointOnPlane, pointPolar, pointCylindrical, projectPointToPlane, populate3D
    case constructPointPolar
    // Plane (additions)
    case planeThreePt, planeFlip
    // Transform (additions)
    case geoProject, geoTwist, geoTaper
    // Geometry – primitive constructors (additions)
    case geoLineSDL, geoCircleThreePt, geoArcThreePt, geoPolyline
    // Curve (additions)
    case curveExplode, curveJoin, curveFrame, curveArea
    // Surface (additions)
    case surfaceFourPoint, surfaceArea, meshClosestPoint
    // Solid / Mesh (additions)
    case deconstructMesh, meshArea, joinMeshes, weldMesh, deconstructBox
    // Geometry – more primitives (additions)
    case geoBoxTwoPt, geoBoxOriented, geoCylinderTwoPt, geoPyramid
    // Plane (additions)
    case planeBetweenLines
    // Math – trig / rounding / constants (additions)
    case sine, cosine, tangent, arcsine, arccosine, arctangent2
    case squareRoot, mathRound, mathFloor, mathCeiling, mathTruncate, mathMin, mathMax
    case degreesToRadians, radiansToDegrees, constantPi, mathLog, mathExp
    // Math – expression (additions)
    case mathExpression
    // Logic (additions)
    case logicXor
    // Vector (additions)
    case vectorSetLength, unitX, unitY, unitZ
    // Params – Color (additions)
    case constructColor, deconstructColor
    // Params – Color (construct variants)
    case constructColorRGB, constructColorPicker
    // Curve (additions)
    case curveDivideLength, evaluateCurve, curveCurvature, isCurveClosed
    // Solid / Mesh (additions)
    case isMeshClosed, flipMesh
    // Intersect (additions)
    case lineSphereIntersect, spherePlaneIntersect, pointInBox
    // Curve – Spline (additions)
    case curveNurbsCurve, curveControlPoints, curveRebuild
    // Utility (additions)
    case mergeGeometry

    var defaultLabel: String {
        switch self {
        case .numberSlider: return "Number Slider"
        case .numberInput: return "Number Input"
        case .booleanToggle: return "Boolean"
        case .textInput: return "Text"
        case .colorPicker: return "Color"
        case .point2D: return "Point"
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        case .divide: return "Divide"
        case .modulo: return "Modulo"
        case .power: return "Power"
        case .absolute: return "Absolute"
        case .negate: return "Negate"
        case .logicAnd: return "And"
        case .logicOr: return "Or"
        case .logicNot: return "Not"
        case .greaterThan: return "Greater Than"
        case .lessThan: return "Less Than"
        case .equality: return "Equality"
        case .concatenate: return "Concatenate"
        case .textLength: return "Text Length"
        case .uppercase: return "Uppercase"
        case .lowercase: return "Lowercase"
        case .constructPoint: return "Construct Pt"
        case .deconstruct: return "Deconstruct Pt"
        case .distance: return "Distance"
        case .vectorAdd: return "Vector Add"
        case .vectorScale: return "Vector Scale"
        case .output: return "Output"
        case .remap: return "Remap"
        case .clamp: return "Clamp"
        case .lerp: return "Lerp"
        // Geometry – 2D
        case .geoPoint:     return "Point"
        case .geoLine:      return "Line"
        case .geoCircle:    return "Circle"
        case .geoPolygon:   return "Polygon"
        case .geoGrid:      return "Grid"
        case .geoRectangle: return "Rectangle"
        case .geoEllipse:   return "Ellipse"
        case .geoArc:       return "Arc"
        case .geoBezier:    return "Bezier"
        case .geoLoftSurface: return "Loft Surface"
        case .geoBlendArc: return "Blend Arc"
        // Geometry – 3D
        case .geoSphere:    return "Sphere"
        case .geoBox:       return "Box"
        case .geoCylinder:  return "Cylinder"
        case .geoCone:      return "Cone"
        case .geoTorus:     return "Torus"
        // Transforms
        case .geoTranslate: return "Translate"
        case .geoRotate:    return "Rotate"
        case .geoScale:     return "Scale"
        case .material:     return "Material"
        case .materialABSPlastic: return "ABS Plastic"
        case .materialAnodizedAluminum: return "Anodized Aluminum"
        case .materialBrushedStainless: return "Brushed Stainless"
        case .materialBeadBlastedSteel: return "Bead-Blasted Steel"
        case .materialChrome: return "Chrome"
        case .materialVelvet: return "Velvet"
        case .materialWax: return "Frosted Wax"
        case .sceneLighting: return "Scene Lighting"
        case .pointLight: return "Point Light"
        case .objectLight: return "Object Light"
        case .volumetricFog: return "Volumetric Fog"
        // 2D Shapes
        case .shape2DPoint:   return "Point"
        case .shape2DLine:    return "Line"
        case .shape2DSquare:  return "Square"
        case .shape2DEllipse: return "Ellipse"
        case .shape2DRectangle:        return "Rectangle"
        case .shape2DRectangleCorners: return "Rectangle 2Pt"
        case .shape2DSemicircle:       return "Semicircle"
        // Vector – Planes
        case .constructPlane:   return "Construct Plane"
        case .deconstructPlane: return "Deconstruct Plane"
        case .planeXY:          return "XY Plane"
        case .planeYZ:          return "YZ Plane"
        case .planeZX:          return "ZX Plane"
        // Transform
        case .geoScaleNU:    return "Scale NU"
        case .geoMirror:     return "Mirror"
        case .geoArrayLinear: return "Array Linear"
        case .geoArrayPolar: return "Array Polar"
        case .geoOrient:     return "Orient"
        // Curve
        case .curveDivide:         return "Divide Curve"
        case .curveLength:         return "Length"
        case .curvePointAt:        return "Point On Curve"
        case .curveEndPoints:      return "End Points"
        case .curveExtend:         return "Extend Curve"
        case .curveOffset:         return "Offset Curve"
        case .curveFillet:         return "Fillet Curve"
        case .curveInterpolate:    return "Interpolate"
        case .curveClosestPoint:   return "Curve Closest Point"
        case .curveCurveIntersect: return "Curve | Curve"
        // Surface
        case .surfaceExtrude:      return "Extrude"
        case .surfaceExtrudePoint: return "Extrude Point"
        case .surfaceRevolve:      return "Revolve"
        case .surfaceSweep1:       return "Sweep1"
        case .surfaceBoundary:     return "Boundary Surface"
        case .surfaceOffset:       return "Offset Surface"
        case .surfacePipe:         return "Pipe"
        // Solid
        case .solidUnion:        return "Union"
        case .solidDifference:   return "Difference"
        case .solidIntersection: return "Intersection"
        case .solidCapHoles:     return "Cap Holes"
        case .solidBoundingBox:  return "Bounding Box"
        case .solidVolume:       return "Volume"
        case .solidCentroid:     return "Centroid"
        // Intersect
        case .meshPlaneSection: return "Mesh | Plane"
        case .lineLineIntersect: return "Line | Line"
        case .planePlaneIntersect: return "Plane | Plane"
        case .planeLineIntersect: return "Plane | Line"
        case .pointPlaneDistance: return "Point/Plane Distance"
        // Vector (additions)
        case .vectorTwoPt: return "Vector 2Pt"
        case .vectorUnitize: return "Unit Vector"
        case .vectorLength: return "Vector Length"
        case .vectorReverse: return "Reverse Vector"
        case .vectorCrossProduct: return "Cross Product"
        case .vectorDotProduct: return "Dot Product"
        case .vectorRotate: return "Vector Rotate"
        case .vectorAngle: return "Angle"
        // Point (additions)
        case .pointOnPlane: return "Point On Plane"
        case .pointPolar: return "Point Polar"
        case .pointCylindrical: return "Point Cylindrical"
        case .constructPointPolar: return "Construct Point (Polar)"
        case .projectPointToPlane: return "Project Point"
        case .populate3D: return "Populate 3D"
        // Plane (additions)
        case .planeThreePt: return "Plane 3Pt"
        case .planeFlip: return "Flip Plane"
        // Transform (additions)
        case .geoProject: return "Project"
        case .geoTwist: return "Twist"
        case .geoTaper: return "Taper"
        // Geometry primitives (additions)
        case .geoLineSDL: return "Line SDL"
        case .geoCircleThreePt: return "Circle 3Pt"
        case .geoArcThreePt: return "Arc 3Pt"
        case .geoPolyline: return "Polyline"
        // Curve (additions)
        case .curveExplode: return "Explode"
        case .curveJoin: return "Join Curves"
        case .curveFrame: return "Curve Frame"
        case .curveArea: return "Area"
        // Surface (additions)
        case .surfaceFourPoint: return "Surface 4Pt"
        case .surfaceArea: return "Surface Area"
        case .meshClosestPoint: return "Mesh Closest Point"
        // Solid / Mesh (additions)
        case .deconstructMesh: return "Deconstruct Mesh"
        case .meshArea: return "Mesh Area"
        case .joinMeshes: return "Join Meshes"
        case .weldMesh: return "Weld Mesh"
        case .deconstructBox: return "Deconstruct Box"
        // Geometry – more primitives (additions)
        case .geoBoxTwoPt: return "Box 2Pt"
        case .geoBoxOriented: return "Box Oriented"
        case .geoCylinderTwoPt: return "Cylinder 2Pt"
        case .geoPyramid: return "Pyramid"
        // Plane (additions)
        case .planeBetweenLines: return "Plane Between Curves"
        // Math – trig / rounding / constants (additions)
        case .sine: return "Sine"
        case .cosine: return "Cosine"
        case .tangent: return "Tangent"
        case .arcsine: return "Arcsine"
        case .arccosine: return "Arccosine"
        case .arctangent2: return "Atan2"
        case .squareRoot: return "Square Root"
        case .mathRound: return "Round"
        case .mathFloor: return "Floor"
        case .mathCeiling: return "Ceiling"
        case .mathTruncate: return "Truncate"
        case .mathMin: return "Minimum"
        case .mathMax: return "Maximum"
        case .degreesToRadians: return "To Radians"
        case .radiansToDegrees: return "To Degrees"
        case .constantPi: return "Pi"
        case .mathLog: return "Log"
        case .mathExp: return "Exp"
        case .mathExpression: return "Expression"
        // Logic (additions)
        case .logicXor: return "Xor"
        // Vector (additions)
        case .vectorSetLength: return "Set Vector Length"
        case .unitX: return "Unit X"
        case .unitY: return "Unit Y"
        case .unitZ: return "Unit Z"
        // Params – Color (additions)
        case .constructColor: return "Construct Color"
        case .deconstructColor: return "Deconstruct Color"
        case .constructColorRGB: return "Construct Color (RGB)"
        case .constructColorPicker: return "Construct Color (Picker)"
        // Curve (additions)
        case .curveDivideLength: return "Divide By Length"
        case .evaluateCurve: return "Evaluate Curve"
        case .curveCurvature: return "Curvature"
        case .isCurveClosed: return "Is Curve Closed"
        // Solid / Mesh (additions)
        case .isMeshClosed: return "Is Mesh Closed"
        case .flipMesh: return "Flip Mesh"
        // Intersect (additions)
        case .lineSphereIntersect: return "Line | Sphere"
        case .spherePlaneIntersect: return "Sphere | Plane"
        case .pointInBox: return "Point In Box"
        // Curve – Spline (additions)
        case .curveNurbsCurve: return "Nurbs Curve"
        case .curveControlPoints: return "Control Points"
        case .curveRebuild: return "Rebuild Curve"
        case .mergeGeometry: return "Merge Geometry"
        }
    }

    /// Nodes that belong to the 3D geometry pipeline — hidden from the library when in 2D mode.
    /// This is every node in the vector3-based categories (`.geometry`, `.transform`, `.curve`,
    /// `.surface`, `.solid`, `.intersect`, `.vector`).
    var is3DOnly: Bool {
        switch category {
        case .geometry, .transform, .curve, .surface, .solid, .intersect, .vector:
            // `.vector` is entirely vector3-based (points, planes, cross/dot products,
            // unit axes, etc.) — there is no 2D-native member of this category.
            return true
        default:
            return false
        }
    }

    /// Nodes that belong to the pure 2D shape pipeline — hidden from the library when in 3D mode.
    var is2DOnly: Bool {
        category == .geometry2D || self == .point2D
    }

    /// Groups nodes within a `NodeCategory` into named panels for the
    /// ribbon-style library UI (mirrors Grasshopper's tab → panel layout).
    /// `nil` means the node is shown ungrouped within its category tab.
    var subcategory: String? {
        switch self {
        case .constructPlane, .deconstructPlane, .planeXY, .planeYZ, .planeZX, .planeThreePt, .planeFlip,
             .planeBetweenLines:
            return "Plane"
        case .geoSphere, .geoBox, .geoCylinder, .geoCone, .geoTorus,
             .geoBoxTwoPt, .geoBoxOriented, .geoCylinderTwoPt, .geoPyramid:
            return "Primitive"
        case .material, .materialABSPlastic, .materialAnodizedAluminum,
             .materialBrushedStainless, .materialBeadBlastedSteel, .materialChrome,
             .materialVelvet, .materialWax:
            return "Material"
        case .sceneLighting, .pointLight, .objectLight, .volumetricFog:
            return "Lighting"
        case .pointOnPlane, .pointPolar, .pointCylindrical, .projectPointToPlane, .populate3D, .constructPointPolar:
            return "Point"
        case .geoTranslate, .geoRotate, .geoScale:
            return "Euclidean"
        case .geoArrayLinear, .geoArrayPolar:
            return "Array"
        case .geoMirror, .geoOrient, .geoScaleNU, .geoProject:
            return "Affine"
        case .geoTwist, .geoTaper:
            return "Deform"
        case .curveDivide, .curvePointAt, .curveClosestPoint:
            return "Division"
        case .curveExtend, .curveOffset, .curveFillet, .curveExplode, .curveJoin:
            return "Util"
        case .curveLength, .curveEndPoints, .curveFrame, .curveArea:
            return "Analysis"
        case .curveCurveIntersect:
            return "Intersect"
        case .curveInterpolate, .curveNurbsCurve, .curveControlPoints, .curveRebuild:
            return "Spline"
        case .geoLoftSurface, .surfaceSweep1, .surfaceRevolve, .surfaceExtrude, .surfaceExtrudePoint, .surfaceFourPoint:
            return "Freeform"
        case .surfaceOffset, .surfaceBoundary, .surfacePipe:
            return "Util"
        case .surfaceArea, .meshClosestPoint:
            return "Analysis"
        case .solidUnion, .solidDifference, .solidIntersection:
            return "Boolean"
        case .solidBoundingBox, .solidVolume, .solidCentroid, .deconstructBox:
            return "Analysis"
        case .solidCapHoles:
            return "Util"
        case .deconstructMesh, .meshArea, .joinMeshes, .weldMesh, .isMeshClosed, .flipMesh:
            return "Mesh"
        case .sine, .cosine, .tangent, .arcsine, .arccosine, .arctangent2, .degreesToRadians, .radiansToDegrees:
            return "Trig"
        case .mathRound, .mathFloor, .mathCeiling, .mathTruncate, .mathMin, .mathMax:
            return "Rounding"
        case .constructColor, .deconstructColor, .constructColorRGB, .constructColorPicker:
            return "Color"
        case .curveDivideLength, .evaluateCurve:
            return "Division"
        case .curveCurvature, .isCurveClosed:
            return "Analysis"
        default:
            return nil
        }
    }

    var category: NodeCategory {
        switch self {
        case .numberSlider, .numberInput, .booleanToggle, .textInput, .colorPicker, .point2D,
             .constructColor, .deconstructColor, .constructColorRGB, .constructColorPicker:
            return .params
        case .add, .subtract, .multiply, .divide, .modulo, .power, .absolute, .negate,
             .sine, .cosine, .tangent, .arcsine, .arccosine, .arctangent2,
             .squareRoot, .mathRound, .mathFloor, .mathCeiling, .mathTruncate, .mathMin, .mathMax,
             .degreesToRadians, .radiansToDegrees, .constantPi, .mathLog, .mathExp, .mathExpression:
            return .math
        case .logicAnd, .logicOr, .logicNot, .greaterThan, .lessThan, .equality, .logicXor:
            return .logic
        case .concatenate, .textLength, .uppercase, .lowercase:
            return .text
        case .constructPoint, .deconstruct, .distance, .vectorAdd, .vectorScale,
             .constructPlane, .deconstructPlane, .planeXY, .planeYZ, .planeZX,
             .vectorTwoPt, .vectorUnitize, .vectorLength, .vectorReverse,
             .vectorCrossProduct, .vectorDotProduct, .vectorRotate, .vectorAngle,
             .pointOnPlane, .pointPolar, .pointCylindrical, .projectPointToPlane, .populate3D,
             .constructPointPolar,
             .planeThreePt, .planeFlip, .planeBetweenLines,
             .vectorSetLength, .unitX, .unitY, .unitZ:
            return .vector
        case .output, .remap, .clamp, .lerp, .mergeGeometry:
            return .utility
        case .geoPoint, .geoLine, .geoCircle, .geoPolygon, .geoGrid,
             .geoRectangle, .geoEllipse, .geoArc, .geoBezier,
             .geoBlendArc,
             .geoSphere, .geoBox, .geoCylinder, .geoCone, .geoTorus,
             .material, .materialABSPlastic, .materialAnodizedAluminum,
             .materialBrushedStainless, .materialBeadBlastedSteel, .materialChrome,
             .materialVelvet, .materialWax,
             .sceneLighting, .pointLight, .objectLight, .volumetricFog,
             .geoLineSDL, .geoCircleThreePt, .geoArcThreePt, .geoPolyline,
             .geoBoxTwoPt, .geoBoxOriented, .geoCylinderTwoPt, .geoPyramid:
            return .geometry
        case .shape2DPoint, .shape2DLine, .shape2DSquare, .shape2DEllipse,
             .shape2DRectangle, .shape2DRectangleCorners, .shape2DSemicircle:
            return .geometry2D
        case .geoTranslate, .geoRotate, .geoScale, .geoScaleNU, .geoMirror,
             .geoArrayLinear, .geoArrayPolar, .geoOrient, .geoProject, .geoTwist, .geoTaper:
            return .transform
        case .curveDivide, .curveLength, .curvePointAt, .curveEndPoints, .curveExtend,
             .curveOffset, .curveFillet, .curveInterpolate, .curveClosestPoint, .curveCurveIntersect,
             .curveExplode, .curveJoin, .curveFrame, .curveArea,
             .curveDivideLength, .evaluateCurve, .curveCurvature, .isCurveClosed,
             .curveNurbsCurve, .curveControlPoints, .curveRebuild:
            return .curve
        case .geoLoftSurface, .surfaceExtrude, .surfaceExtrudePoint, .surfaceRevolve,
             .surfaceSweep1, .surfaceBoundary, .surfaceOffset, .surfacePipe,
             .surfaceFourPoint, .surfaceArea, .meshClosestPoint:
            return .surface
        case .solidUnion, .solidDifference, .solidIntersection, .solidCapHoles,
             .solidBoundingBox, .solidVolume, .solidCentroid,
             .deconstructMesh, .meshArea, .joinMeshes, .weldMesh, .deconstructBox,
             .isMeshClosed, .flipMesh:
            return .solid
        case .meshPlaneSection, .lineLineIntersect,
             .planePlaneIntersect, .planeLineIntersect, .pointPlaneDistance,
             .lineSphereIntersect, .spherePlaneIntersect, .pointInBox:
            return .intersect
        }
    }

    var systemImage: String {
        switch self {
        case .numberSlider: return "slider.horizontal.3"
        case .numberInput: return "number"
        case .booleanToggle: return "togglepower"
        case .textInput: return "text.cursor"
        case .colorPicker: return "paintpalette"
        case .point2D: return "dot.square"
        case .add: return "plus"
        case .subtract: return "minus"
        case .multiply: return "multiply"
        case .divide: return "divide"
        case .modulo: return "percent"
        case .power: return "x.squareroot"
        case .absolute: return "abs"
        case .negate: return "minus.circle"
        case .logicAnd: return "circle.grid.2x2"
        case .logicOr: return "circle.grid.3x3"
        case .logicNot: return "exclamationmark.circle"
        case .greaterThan: return "greaterthan"
        case .lessThan: return "lessthan"
        case .equality: return "equal"
        case .concatenate: return "text.append"
        case .textLength: return "character.cursor.ibeam"
        case .uppercase: return "textformat.characters.largecaps"
        case .lowercase: return "textformat.abc"
        case .constructPoint: return "scope"
        case .deconstruct: return "arrow.up.left.and.down.right.magnifyingglass"
        case .distance: return "ruler"
        case .vectorAdd: return "arrow.up.right"
        case .vectorScale: return "arrow.up.right.and.arrow.down.left"
        case .output: return "square.and.arrow.up"
        case .remap: return "arrow.left.arrow.right"
        case .clamp: return "arrow.left.to.line.alt"
        case .lerp: return "slider.horizontal.below.rectangle"
        // Geometry – 2D
        case .geoPoint:     return "smallcircle.filled.circle"
        case .geoLine:      return "line.diagonal"
        case .geoCircle:    return "circle"
        case .geoPolygon:   return "hexagon"
        case .geoGrid:      return "grid"
        case .geoRectangle: return "rectangle"
        case .geoEllipse:   return "oval"
        case .geoArc:       return "arrow.clockwise"
        case .geoBezier:    return "scribble"
        case .geoLoftSurface: return "square.stack.3d.up"
        case .geoBlendArc: return "arrow.triangle.branch"
        // Geometry – 3D
        case .geoSphere:    return "globe"
        case .geoBox:       return "cube"
        case .geoCylinder:  return "cylinder"
        case .geoCone:      return "cone"
        case .geoTorus:     return "circle.dotted"
        // Transforms
        case .geoTranslate: return "move.3d"
        case .geoRotate:    return "rotate.3d"
        case .geoScale:     return "arrow.up.left.and.arrow.down.right"
        // Material
        case .material:     return "paintbrush.pointed"
        case .materialABSPlastic: return "capsule.lefthalf.filled"
        case .materialAnodizedAluminum: return "square.stack.3d.forward.dottedline"
        case .materialBrushedStainless: return "cylinder.split.1x2"
        case .materialBeadBlastedSteel: return "square.grid.3x3.topleft.filled"
        case .materialChrome: return "sparkles.rectangle.stack"
        case .materialVelvet: return "theatermasks.fill"
        case .materialWax: return "drop.fill"
        case .sceneLighting: return "sun.max.fill"
        case .pointLight: return "lightbulb.fill"
        case .objectLight: return "light.panel.fill"
        case .volumetricFog: return "cloud.fog.fill"
        // 2D Shapes
        case .shape2DPoint:   return "dot.circle"
        case .shape2DLine:    return "line.diagonal"
        case .shape2DSquare:  return "square"
        case .shape2DEllipse: return "oval"
        case .shape2DRectangle:        return "rectangle"
        case .shape2DRectangleCorners: return "rectangle.dashed"
        case .shape2DSemicircle:       return "circle.lefthalf.filled"
        // Vector – Planes
        case .constructPlane:   return "square.on.circle"
        case .deconstructPlane: return "square.dashed"
        case .planeXY:          return "square.grid.3x3"
        case .planeYZ:          return "square.grid.3x3"
        case .planeZX:          return "square.grid.3x3"
        // Transform
        case .geoScaleNU:     return "arrow.up.left.and.down.right.magnifyingglass"
        case .geoMirror:      return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .geoArrayLinear: return "square.grid.4x3.fill"
        case .geoArrayPolar:  return "circle.grid.3x3.fill"
        case .geoOrient:      return "arrow.triangle.turn.up.right.diamond"
        // Curve
        case .curveDivide:         return "divide.circle"
        case .curveLength:         return "ruler"
        case .curvePointAt:        return "smallcircle.filled.circle"
        case .curveEndPoints:      return "circle.and.line.horizontal"
        case .curveExtend:         return "arrow.up.right.and.arrow.down.left.rectangle"
        case .curveOffset:         return "square.on.square"
        case .curveFillet:         return "circle.tophalf.filled"
        case .curveInterpolate:    return "waveform.path"
        case .curveClosestPoint:   return "target"
        case .curveCurveIntersect: return "point.topleft.down.curvedto.point.bottomright.up"
        // Surface
        case .surfaceExtrude:      return "square.and.arrow.up.fill"
        case .surfaceExtrudePoint: return "triangle"
        case .surfaceRevolve:      return "arrow.triangle.2.circlepath"
        case .surfaceSweep1:       return "wind"
        case .surfaceBoundary:     return "square.dashed.inset.filled"
        case .surfaceOffset:       return "square.stack"
        case .surfacePipe:         return "cylinder.split.1x2"
        // Solid
        case .solidUnion:        return "circle.hexagongrid.fill"
        case .solidDifference:   return "minus.circle"
        case .solidIntersection: return "circle.grid.cross"
        case .solidCapHoles:     return "capsule.portrait"
        case .solidBoundingBox:  return "shippingbox"
        case .solidVolume:       return "cube.transparent"
        case .solidCentroid:     return "scope"
        // Intersect
        case .meshPlaneSection:  return "square.stack.3d.forward.dottedline"
        case .lineLineIntersect: return "point.3.connected.trianglepath.dotted"
        case .planePlaneIntersect: return "square.stack"
        case .planeLineIntersect:  return "point.topleft.down.curvedto.point.bottomright.up"
        case .pointPlaneDistance:  return "ruler"
        // Vector (additions)
        case .vectorTwoPt:         return "arrow.up.right"
        case .vectorUnitize:       return "1.circle"
        case .vectorLength:        return "ruler"
        case .vectorReverse:       return "arrow.uturn.left"
        case .vectorCrossProduct:  return "xmark"
        case .vectorDotProduct:    return "smallcircle.filled.circle"
        case .vectorRotate:        return "arrow.triangle.2.circlepath"
        case .vectorAngle:         return "triangle"
        // Point (additions)
        case .pointOnPlane:        return "square.on.circle"
        case .pointPolar:          return "circle.grid.cross"
        case .pointCylindrical:    return "cylinder"
        case .constructPointPolar: return "location.north.circle"
        case .projectPointToPlane: return "arrow.down.to.line"
        case .populate3D:          return "circle.grid.3x3.fill"
        // Plane (additions)
        case .planeThreePt: return "square.on.circle"
        case .planeFlip:    return "arrow.up.arrow.down"
        // Transform (additions)
        case .geoProject: return "arrow.down.to.line"
        case .geoTwist:   return "tornado"
        case .geoTaper:   return "triangle"
        // Geometry primitives (additions)
        case .geoLineSDL:       return "line.diagonal"
        case .geoCircleThreePt: return "circle"
        case .geoArcThreePt:    return "arrow.clockwise"
        case .geoPolyline:      return "point.3.connected.trianglepath.dotted"
        // Curve (additions)
        case .curveExplode: return "square.split.2x1"
        case .curveJoin:    return "link"
        case .curveFrame:   return "square.on.circle"
        case .curveArea:    return "square.dashed"
        // Surface (additions)
        case .surfaceFourPoint: return "square.on.square"
        case .surfaceArea:      return "square.dashed"
        case .meshClosestPoint: return "target"
        // Solid / Mesh (additions)
        case .deconstructMesh: return "list.bullet.rectangle"
        case .meshArea:        return "square.dashed"
        case .joinMeshes:      return "link"
        case .weldMesh:        return "bolt.fill"
        case .deconstructBox:  return "shippingbox"
        // Geometry – more primitives (additions)
        case .geoBoxTwoPt:      return "cube"
        case .geoBoxOriented:   return "cube.fill"
        case .geoCylinderTwoPt: return "cylinder"
        case .geoPyramid:       return "pyramid"
        // Plane (additions)
        case .planeBetweenLines: return "square.on.circle"
        // Math – trig / rounding / constants (additions)
        case .sine:             return "waveform.path"
        case .cosine:           return "waveform.path.ecg"
        case .tangent:          return "waveform"
        case .arcsine:          return "function"
        case .arccosine:        return "function"
        case .arctangent2:      return "function"
        case .squareRoot:       return "x.squareroot"
        case .mathRound:        return "circle.grid.2x2"
        case .mathFloor:        return "arrow.down.to.line"
        case .mathCeiling:      return "arrow.up.to.line"
        case .mathTruncate:     return "scissors"
        case .mathMin:          return "arrow.down.to.line.compact"
        case .mathMax:          return "arrow.up.to.line.compact"
        case .degreesToRadians: return "angle"
        case .radiansToDegrees: return "angle"
        case .constantPi:       return "pi"
        case .mathLog:          return "function"
        case .mathExp:          return "function"
        case .mathExpression:   return "sum"
        // Logic (additions)
        case .logicXor: return "circle.grid.2x2"
        // Vector (additions)
        case .vectorSetLength: return "ruler"
        case .unitX: return "arrow.right"
        case .unitY: return "arrow.up"
        case .unitZ: return "arrow.up.right"
        // Params – Color (additions)
        case .constructColor:   return "paintpalette"
        case .deconstructColor: return "paintpalette"
        case .constructColorRGB:     return "paintpalette"
        case .constructColorPicker:  return "eyedropper"
        // Curve (additions)
        case .curveDivideLength: return "ruler"
        case .evaluateCurve:     return "smallcircle.filled.circle"
        case .curveCurvature:    return "circle.dashed"
        case .isCurveClosed:     return "checkmark.circle"
        // Solid / Mesh (additions)
        case .isMeshClosed: return "checkmark.seal"
        case .flipMesh:     return "arrow.triangle.2.circlepath"
        // Intersect (additions)
        case .lineSphereIntersect:  return "circle.circle"
        case .spherePlaneIntersect: return "circle.circle"
        case .pointInBox:           return "shippingbox"
        // Curve – Spline (additions)
        case .curveNurbsCurve:      return "point.3.connected.trianglepath.dotted"
        case .curveControlPoints:   return "circle.grid.2x2"
        case .curveRebuild:         return "arrow.triangle.2.circlepath"
        case .mergeGeometry:        return "rectangle.stack"
        }
    }
}

enum NodeCategory: String, CaseIterable {
    case params = "Params"
    case math = "Math"
    case logic = "Logic"
    case text = "Text"
    case vector = "Vector"
    case utility = "Utility"
    case geometry = "Geometry"
    case geometry2D = "2D Shapes"
    case transform = "Transform"
    case curve = "Curve"
    case surface = "Surface"
    case solid = "Solid"
    case intersect = "Intersect"

    var color: Color {
        switch self {
        case .params:   return .blue
        case .math:     return .orange
        case .logic:    return .red
        case .text:     return .purple
        case .vector:   return .green
        case .utility:  return .gray
        case .geometry: return .teal
        case .geometry2D: return .mint
        case .transform: return .indigo
        case .curve:     return .cyan
        case .surface:   return .brown
        case .solid:     return .pink
        case .intersect: return .yellow
        }
    }

    var systemImage: String {
        switch self {
        case .params:   return "slider.horizontal.3"
        case .math:     return "function"
        case .logic:    return "circle.grid.2x2"
        case .text:     return "text.alignleft"
        case .vector:   return "arrow.up.right"
        case .utility:  return "wrench.and.screwdriver"
        case .geometry: return "square.3.layers.3d"
        case .geometry2D: return "square.2.layers.3d"
        case .transform: return "move.3d"
        case .curve:     return "scribble.variable"
        case .surface:   return "square.stack.3d.up.fill"
        case .solid:     return "cube.fill"
        case .intersect: return "asterisk.circle"
        }
    }

    var kinds: [NodeKind] {
        NodeKind.allCases.filter { $0.category == self }
    }
}

// MARK: - NodeGraph

class NodeGraph: ObservableObject {
    let id = UUID()
    private static let outputStylePortCount = 2
    private static let outputMinimumGeometryPortCount = 1
    private static let outputFreeGeometryPortBuffer = 2
    private static let outputGeometryPortGrowthChunk = 8

    @Published var nodes: [Node] = [] {
        didSet {
            bindNodes()
            guard !isRestoring else { return }
            normalizeOutputNodes()
            markDirty()
        }
    }
    @Published var connections: [Connection] = [] {
        didSet {
            guard !isRestoring else { return }
            markDirty()
        }
    }
    @Published var previewShapes: [GeometricShape] = []
    @Published var previewTrackedShapes: [TrackedShape] = []
    @Published var hoveredNodeID: UUID? = nil
    @Published var hoveredConnectionID: UUID? = nil
    /// The node currently held down with the right mouse button, if any.
    /// Drives the "highlight connected nodes and wires" interaction.
    @Published var pressedNodeID: UUID? = nil

    /// Connections attached to `pressedNodeID`, highlighted the same way a hovered wire is.
    var pressHighlightedConnectionIDs: Set<UUID> {
        guard let pressedNodeID else { return [] }
        return Set(connections
            .filter { $0.fromNodeID == pressedNodeID || $0.toNodeID == pressedNodeID }
            .map(\.id))
    }

    /// `pressedNodeID` plus every node directly connected to it.
    var pressHighlightedNodeIDs: Set<UUID> {
        guard let pressedNodeID else { return [] }
        var ids: Set<UUID> = [pressedNodeID]
        for conn in connections where conn.fromNodeID == pressedNodeID || conn.toNodeID == pressedNodeID {
            ids.insert(conn.fromNodeID)
            ids.insert(conn.toNodeID)
        }
        return ids
    }

    // Stable shape identity (Phase B). Maps each Output node's UUID to the
    // positional UUID list for its output stream. Persisted across evaluations
    // so the renderer can diff entities by id.
    private var shapeIDsByOutputNode: [UUID: [UUID]] = [:]

    // The current RenderConfig aggregated from connected render-config nodes
    // (Phase D). Defaults to cinematic defaults if no overrides are wired up.
    @Published var renderConfig: RenderConfig = .cinematicDefault

    // MARK: - File Management

    @Published var currentFileURL: URL? = nil
    @Published var hasUnsavedChanges: Bool = false
    var isRestoring: Bool = false

    var displayTitle: String {
        let name = currentFileURL?.lastPathComponent ?? "Untitled"
        return hasUnsavedChanges ? "\(name) — Edited" : name
    }

    /// The view mode implied by this graph's nodes — 2D-pipeline graphs resolve to `.twoD`,
    /// 3D-pipeline graphs resolve to `.perspective`. `nil` when the graph has no geometry
    /// nodes to infer a pipeline from (e.g. a pure math graph), leaving the view mode as-is.
    var impliedViewMode: ViewMode? {
        if nodes.contains(where: { $0.kind.is2DOnly }) { return .twoD }
        if nodes.contains(where: { $0.kind.is3DOnly }) { return .perspective }
        return nil
    }

    private var nodeSubscriptions: [UUID: AnyCancellable] = [:]

    init() {
        bindNodes()
        normalizeOutputNodes()
    }

    private func markDirty() {
        guard !isRestoring else { return }
        hasUnsavedChanges = true
    }

    func addNode(_ node: Node) {
        nodes.append(node)
        normalizeOutputPorts(for: node)
        evaluate()
    }

    func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        if hoveredNodeID == id {
            hoveredNodeID = nil
        }
        if pressedNodeID == id {
            pressedNodeID = nil
        }
        if !connections.contains(where: { $0.id == hoveredConnectionID }) {
            hoveredConnectionID = nil
        }
        // Phase B cleanup: drop UUID list for any removed Output node.
        shapeIDsByOutputNode.removeValue(forKey: id)
        normalizeOutputNodes()
        evaluate()
    }

    /// Two ports may only be wired together when their data types match (or
    /// either side is `.any`, a wildcard for future generic nodes) — this is
    /// what lets the wire/point color double as a connectability cue.
    func portTypesAreCompatible(_ a: PortType, _ b: PortType) -> Bool {
        a == b || a == .any || b == .any
    }

    func addConnection(_ conn: Connection) {
        guard
            let fromNode = node(id: conn.fromNodeID),
            let fromPort = fromNode.outputs.first(where: { $0.id == conn.fromPortID }),
            let toNode = node(id: conn.toNodeID),
            let toPort = toNode.inputs.first(where: { $0.id == conn.toPortID }),
            portTypesAreCompatible(fromPort.type, toPort.type)
        else {
            FileHandle.standardError.write("DEBUG: addConnection REJECTED\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardError.write("DEBUG: addConnection ACCEPTED\n".data(using: .utf8)!)

        let resolvedConnection = resolveConnectionTarget(for: conn)

        // Remove existing connection to the same input port
        connections.removeAll {
            $0.toNodeID == resolvedConnection.toNodeID && $0.toPortID == resolvedConnection.toPortID
        }
        connections.append(resolvedConnection)
        if let node = node(id: resolvedConnection.toNodeID) {
            normalizeOutputPorts(for: node)
            normalizeAddInputPorts(for: node)
        }
        evaluate()
    }

    func removeConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if hoveredConnectionID == id {
            hoveredConnectionID = nil
        }
        normalizeOutputNodes()
        evaluate()
    }

    func node(id: UUID) -> Node? {
        nodes.first { $0.id == id }
    }

    private func bindNodes() {
        let validIDs = Set(nodes.map(\.id))
        nodeSubscriptions = nodeSubscriptions.filter { validIDs.contains($0.key) }

        for node in nodes where nodeSubscriptions[node.id] == nil {
            nodeSubscriptions[node.id] = node.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                    self?.markDirty()
                }
            }
        }
    }

    func portValue(nodeID: UUID, portID: UUID) -> PortValue? {
        guard let node = node(id: nodeID) else { return nil }
        return (node.outputs + node.inputs).first { $0.id == portID }?.value
    }

    // Topological evaluation. Schedules a debounced+cancellable evaluation via
    // the shared coordinator. Use `runEvaluationNow()` if you need the work
    // to happen synchronously on the current thread (e.g. for unit tests).
    func evaluate() {
        Task {
            await EvaluationCoordinator.shared.schedule(self)
        }
    }

    /// The synchronous body of the evaluation pipeline. Called from
    /// `EvaluationCoordinator` once debounce completes (on the main thread).
    func runEvaluationNow() {
        normalizeOutputNodes()

        // Build adjacency: node -> nodes it depends on
        var inDegree = [UUID: Int]()
        var deps = [UUID: [UUID]]()
        for node in nodes {
            inDegree[node.id] = 0
            deps[node.id] = []
        }
        for conn in connections {
            deps[conn.toNodeID, default: []].append(conn.fromNodeID)
            inDegree[conn.toNodeID, default: 0] += 1
        }

        var queue = nodes.filter { inDegree[$0.id] == 0 }.map { $0.id }
        var order = [UUID]()
        while !queue.isEmpty {
            let id = queue.removeFirst()
            order.append(id)
            for conn in connections where conn.fromNodeID == id {
                inDegree[conn.toNodeID, default: 1] -= 1
                if inDegree[conn.toNodeID] == 0 {
                    queue.append(conn.toNodeID)
                }
            }
        }

        for nodeID in order {
            guard let node = self.node(id: nodeID) else { continue }
            // Pull values from connected outputs into inputs. An input with no
            // live connection must be cleared (not left holding a stale value
            // from a since-removed wire) — NodeEvaluator supplies its own
            // fallback for nil, and unpaintedShapes(for:) treats a nil/absent
            // geometry value as "no shapes", which is what drops disconnected
            // geometry out of the render output.
            for i in node.inputs.indices {
                if let conn = connections.first(where: { $0.toNodeID == nodeID && $0.toPortID == node.inputs[i].id }),
                   let srcNode = self.node(id: conn.fromNodeID),
                   let srcPort = srcNode.outputs.first(where: { $0.id == conn.fromPortID }) {
                    node.inputs[i].value = srcPort.value
                } else {
                    node.inputs[i].value = nil
                }
            }
            NodeEvaluator.evaluate(node: node)
        }

        let unpaintedByOutputNode = nodes
            .filter { $0.kind == .output }
            .map { (node: $0, shapes: unpaintedShapes(for: $0)) }

        var allTracked: [TrackedShape] = []
        for (node, unpainted) in unpaintedByOutputNode {
            let tracked = trackedShapes(for: node, shapes: unpainted)
            allTracked.append(contentsOf: tracked)
        }

        previewTrackedShapes = allTracked
        // Keep previewShapes in sync as a derived property for the 2D path.
        previewShapes = allTracked.map(\.shape)

        // Aggregate RenderConfig from render-config-producing nodes.
        renderConfig = aggregateRenderConfig()
    }

    /// Flat list of unpainted shapes for an Output node (no material wrapping).
    private func unpaintedShapes(for node: Node) -> [GeometricShape] {
        guard node.kind == .output else { return [] }
        let geometryPortCount = outputGeometryPortCount(for: node)

        return node.inputs.prefix(geometryPortCount).flatMap { port -> [GeometricShape] in
            guard case .geometry(let shapes) = port.value else { return [] }
            return shapes
        }
    }

    /// Apply the Output node's material (its single "Mat" input, wired from a
    /// Material node or a preset) uniformly to every shape reaching this
    /// Output, and assign stable UUIDs positionally. UUIDs survive across
    /// evaluations when the positional slot is unchanged (slider drag case).
    ///
    /// Because every shape under one Output node shares this exact same
    /// `Material3D` value (not a per-shape recomputation), shapes that are
    /// "mathematically connected" through a shared Output are painted with
    /// bit-identical material data — there is no float drift to reconcile
    /// here. Cross-Output float-tolerant material de-duplication for
    /// rendering happens in FilamentRenderView's material instance cache.
    private func trackedShapes(for node: Node, shapes: [GeometricShape]) -> [TrackedShape] {
        let geometryPortCount = outputGeometryPortCount(for: node)
        let material: Material3D
        if case .material(let mat) = node.inputs[safe: geometryPortCount]??.value {
            material = mat
        } else {
            material = .default
        }

        let painted = shapes.map { $0.applyingMaterial(material) }

        // Resize the per-Output UUID list to match the new shape count.
        var ids = shapeIDsByOutputNode[node.id] ?? []
        if ids.count < painted.count {
            ids.append(contentsOf: (ids.count..<painted.count).map { _ in UUID() })
        } else if ids.count > painted.count {
            ids.removeLast(ids.count - painted.count)
        }
        shapeIDsByOutputNode[node.id] = ids

        return zip(ids, painted).map { TrackedShape(id: $0, shape: $1) }
    }

    /// Reads the "Env" input on each Output node (wired from a Scene Lighting
    /// node) and returns the first one that's actually connected. Falls back
    /// to the cinematic default when no Output node has an Env input wired.
    private func aggregateRenderConfig() -> RenderConfig {
        for node in nodes where node.kind == .output {
            let geometryPortCount = outputGeometryPortCount(for: node)
            let envIndex = geometryPortCount + 1  // style ports are [Mat, Env]
            if case .renderConfig(let config) = node.inputs[safe: envIndex]??.value {
                return config
            }
        }
        return .cinematicDefault
    }

    private func resolveConnectionTarget(for connection: Connection) -> Connection {
        guard let targetNode = node(id: connection.toNodeID),
              targetNode.kind == .output,
              let tappedInputIndex = targetNode.inputs.firstIndex(where: { $0.id == connection.toPortID })
        else {
            return connection
        }

        let tappedInput = targetNode.inputs[tappedInputIndex]
        guard tappedInput.type == .geometry else {
            return connection
        }

        normalizeOutputPorts(for: targetNode)

        let geometryPortCount = outputGeometryPortCount(for: targetNode)
        let preferredPort = targetNode.inputs[tappedInputIndex]
        let preferredPortIsFree = !connections.contains {
            $0.toNodeID == targetNode.id && $0.toPortID == preferredPort.id
        }
        if preferredPortIsFree {
            return connection
        }

        guard let nextFreePort = targetNode.inputs.prefix(geometryPortCount).first(where: { geometryPort in
            !connections.contains { $0.toNodeID == targetNode.id && $0.toPortID == geometryPort.id }
        }) else {
            return connection
        }

        return Connection(
            id: connection.id,
            fromNodeID: connection.fromNodeID,
            fromPortID: connection.fromPortID,
            toNodeID: connection.toNodeID,
            toPortID: nextFreePort.id
        )
    }

    private func normalizeOutputNodes() {
        for node in nodes {
            normalizeOutputPorts(for: node)
            normalizeAddInputPorts(for: node)
            normalizeMergeGeometryInputPorts(for: node)
            syncExpressionPorts(for: node)
        }
    }

    // MARK: - Expression node dynamic ports

    /// Rebuilds a `.mathExpression` node's input ports from its formula text
    /// — one number input per distinct variable letter, in order of first
    /// appearance (`e`/`pi` are reserved constants and never become ports).
    /// Ports for letters still present keep their identity (and therefore
    /// their wiring); ports for letters no longer referenced are dropped
    /// along with any connection feeding them.
    func syncExpressionPorts(for node: Node) {
        guard node.kind == .mathExpression else { return }

        let desiredNames = MathExpression.variables(in: node.expression)
        guard node.inputs.map(\.name) != desiredNames else { return }

        var existingByName = [String: Port]()
        for port in node.inputs { existingByName[port.name] = port }

        let desiredNameSet = Set(desiredNames)
        let removedIDs = Set(node.inputs.filter { !desiredNameSet.contains($0.name) }.map(\.id))
        if !removedIDs.isEmpty {
            connections.removeAll { $0.toNodeID == node.id && removedIDs.contains($0.toPortID) }
        }

        node.inputs = desiredNames.map { name in
            existingByName[name] ?? Port(name: name, type: .number, isInput: true, value: .number(0))
        }
    }

    private func normalizeOutputPorts(for node: Node) {
        guard node.kind == .output else { return }

        let stylePortCount = Self.outputStylePortCount
        guard node.inputs.count >= stylePortCount else { return }

        let geometryPortCount = outputGeometryPortCount(for: node)
        let geometryInputs = Array(node.inputs.prefix(geometryPortCount))
        let styleInputs = Array(node.inputs.suffix(stylePortCount))

        let connectedGeometryCount = geometryInputs.filter { geometryPort in
            connections.contains { $0.toNodeID == node.id && $0.toPortID == geometryPort.id }
        }.count

        let minimumDesiredGeometryCount = max(
            Self.outputMinimumGeometryPortCount,
            connectedGeometryCount + Self.outputFreeGeometryPortBuffer
        )

        let desiredGeometryCount: Int
        if geometryPortCount < minimumDesiredGeometryCount {
            let shortage = minimumDesiredGeometryCount - geometryPortCount
            let growth = max(Self.outputGeometryPortGrowthChunk, shortage)
            desiredGeometryCount = geometryPortCount + growth
        } else {
            desiredGeometryCount = minimumDesiredGeometryCount
        }

        guard desiredGeometryCount != geometryPortCount else {
            relabelOutputGeometryPorts(node)
            return
        }

        var updatedGeometryInputs = geometryInputs
        if desiredGeometryCount > geometryPortCount {
            for _ in geometryPortCount..<desiredGeometryCount {
                updatedGeometryInputs.append(
                    Port(name: "Geo", type: .geometry, isInput: true)
                )
            }
        } else {
            updatedGeometryInputs = Array(updatedGeometryInputs.prefix(desiredGeometryCount))
        }

        node.inputs = updatedGeometryInputs + styleInputs
        relabelOutputGeometryPorts(node)
    }

    // MARK: - Add / Merge Geometry node dynamic ports

    private static let addMinimumPortCount = 2
    private static let mergeGeometryMinimumPortCount = 2

    private func normalizeAddInputPorts(for node: Node) {
        guard node.kind == .add else { return }
        normalizeGrowableInputPorts(for: node, minimumCount: Self.addMinimumPortCount,
                                     portType: .number, defaultValue: .number(0))
    }

    /// Mirrors `.add`'s "always one free port" growth so a Merge Geometry
    /// node can take any number of curve/geometry lists — plugging in the
    /// last free port grows a new one, and trailing unconnected ports beyond
    /// the buffer collapse back down.
    private func normalizeMergeGeometryInputPorts(for node: Node) {
        guard node.kind == .mergeGeometry else { return }
        normalizeGrowableInputPorts(for: node, minimumCount: Self.mergeGeometryMinimumPortCount,
                                     portType: .geometry, defaultValue: nil)
    }

    /// Keeps every connected input port plus exactly one unconnected buffer
    /// port at the end (never fewer than `minimumCount` total), relabeling
    /// A/B/C/... as ports are added or trimmed. Shared by `.add` (numbers)
    /// and `.mergeGeometry` (geometry lists) — any node whose input count
    /// should track how many wires are actually plugged in.
    private func normalizeGrowableInputPorts(for node: Node, minimumCount: Int, portType: PortType, defaultValue: PortValue?) {
        let isConnected: (Port) -> Bool = { port in
            self.connections.contains { $0.toNodeID == node.id && $0.toPortID == port.id }
        }

        // Find the index of the last connected input port
        let lastConnectedIndex = node.inputs.lastIndex(where: isConnected)

        // Desired: all connected ports + exactly 1 unconnected buffer (minimum total)
        let desiredCount: Int
        if let lastIdx = lastConnectedIndex {
            desiredCount = max(minimumCount, lastIdx + 2) // +1 for 0-based, +1 for buffer
        } else {
            desiredCount = minimumCount // no connections, keep minimum
        }

        // Remove excess unconnected ports from the end
        while node.inputs.count > desiredCount {
            let lastPort = node.inputs.last!
            if isConnected(lastPort) { break } // safety: shouldn't happen, but don't remove connected ports
            node.inputs.removeLast()
        }

        // Add ports if we need more
        while node.inputs.count < desiredCount {
            let name = addPortLabel(for: node.inputs.count)
            node.inputs.append(
                Port(name: name, type: portType, isInput: true, value: defaultValue)
            )
        }
    }

    private func addPortLabel(for index: Int) -> String {
        // A=0, B=1, ..., Z=25, AA=26, AB=27, ...
        var result = ""
        var n = index
        repeat {
            let remainder = n % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    private func relabelOutputGeometryPorts(_ node: Node) {
        guard node.kind == .output else { return }
        let geometryPortCount = outputGeometryPortCount(for: node)
        guard geometryPortCount > 0 else { return }

        for index in 0..<geometryPortCount {
            let label = geometryPortCount == 1 ? "Geo" : "Geo \(index + 1)"
            if node.inputs[index].name != label {
                node.inputs[index] = Port(
                    id: node.inputs[index].id,
                    name: label,
                    type: node.inputs[index].type,
                    isInput: node.inputs[index].isInput,
                    value: node.inputs[index].value
                )
            }
        }
    }

    private func outputGeometryPortCount(for node: Node) -> Int {
        guard node.kind == .output else { return 0 }
        return max(0, node.inputs.count - Self.outputStylePortCount)
    }

    // MARK: - Save / Load

    func graphDocument() -> GraphDocument {
        GraphDocument(graph: self)
    }

    func restore(from doc: GraphDocument) {
        isRestoring = true
        nodes = doc.nodes.map { $0.instantiateNode() }
        connections = doc.connections
        isRestoring = false
        hasUnsavedChanges = false
        evaluate()
    }

    func save(to url: URL) throws {
        let document = graphDocument()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        currentFileURL = url
        hasUnsavedChanges = false
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let document = try decoder.decode(GraphDocument.self, from: data)
        restore(from: document)
        currentFileURL = url
        if let mode = impliedViewMode {
            UserDefaults.standard.set(mode.rawValue, forKey: kViewModeKey)
        }
    }

    func newDocument() {
        isRestoring = true
        nodes.removeAll()
        connections.removeAll()
        isRestoring = false
        currentFileURL = nil
        hasUnsavedChanges = false
    }
}

// MARK: - GraphDocument (serialization)

struct NodeSnapshot: Codable {
    let id: UUID
    let kind: NodeKind
    let position: CGPoint
    let inputs: [Port]
    let outputs: [Port]
    let label: String
    let sliderMin: Double
    let sliderMax: Double
    let sliderStep: Double
    let expression: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, position, inputs, outputs, label, sliderMin, sliderMax, sliderStep, expression
    }

    init(node: Node) {
        self.id = node.id
        self.kind = node.kind
        self.position = node.position
        self.inputs = node.inputs
        self.outputs = node.outputs
        self.label = node.label
        self.sliderMin = node.sliderMin
        self.sliderMax = node.sliderMax
        self.sliderStep = node.sliderStep
        self.expression = node.expression
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        position = try container.decode(CGPoint.self, forKey: .position)
        inputs = try container.decode([Port].self, forKey: .inputs)
        outputs = try container.decode([Port].self, forKey: .outputs)
        label = try container.decode(String.self, forKey: .label)
        sliderMin = try container.decode(Double.self, forKey: .sliderMin)
        sliderMax = try container.decode(Double.self, forKey: .sliderMax)
        sliderStep = try container.decode(Double.self, forKey: .sliderStep)
        // Older saved documents predate the Expression node and won't have this key.
        expression = try container.decodeIfPresent(String.self, forKey: .expression) ?? ""
    }

    func instantiateNode() -> Node {
        let n = Node(
            id: id,
            kind: kind,
            position: position,
            inputs: inputs,
            outputs: outputs,
            label: label
        )
        n.sliderMin = sliderMin
        n.sliderMax = sliderMax
        n.sliderStep = sliderStep
        n.expression = expression
        return n
    }
}

struct GraphDocument: Codable {
    let version: Int
    let nodes: [NodeSnapshot]
    let connections: [Connection]

    init(graph: NodeGraph) {
        self.version = 1
        self.nodes = graph.nodes.map(NodeSnapshot.init)
        self.connections = graph.connections
    }
}

// MARK: - Phase C: Reactive Background Evaluation

/// Debounces and cancels NodeGraph evaluation requests. When a slider drags
/// rapidly, this coalesces dozens of intermediate evaluations into one
/// applied result, keeping the viewport responsive.
///
/// Currently the per-node `NodeEvaluator.evaluate` writes to `Node.outputs`
/// which are observed by SwiftUI. To stay safe, the coordinator only
/// debounces/cancels the *trigger*; the actual evaluation still runs on the
/// main thread when dispatched. Off-main computation can be layered on later
/// once the per-node evaluator is split into pure read/write phases.
actor EvaluationCoordinator {
    static let shared = EvaluationCoordinator()

    private var currentTask: Task<Void, Never>?

    /// Debounce window: short enough that a single slider drag feels live,
    /// long enough that 60Hz events coalesce into one evaluation.
    private static let debounceNanos: UInt64 = 16_000_000  // 16 ms

    /// Cancel any pending evaluation and schedule a new one. Idempotent.
    func schedule(_ graph: NodeGraph) {
        currentTask?.cancel()
        let task = Task { [weak graph] in
            // Debounce.
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            if Task.isCancelled { return }

            guard let graph = graph else { return }

            // Run the actual evaluation on the main thread, since it mutates
            // Node.outputs which is observed by SwiftUI.
            await MainActor.run {
                graph.runEvaluationNow()
            }
        }
        currentTask = task
    }

    func cancelPending() {
        currentTask?.cancel()
        currentTask = nil
    }
}
