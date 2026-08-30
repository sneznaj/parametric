import Foundation
import SwiftUI

enum NodeEvaluator {
    static func evaluate(node: Node) {
        switch node.kind {
        // Params — values are set by UI, just pass through
        case .numberSlider, .numberInput, .booleanToggle, .textInput, .colorPicker, .point2D, .constructColorPicker:
            break

        // Math binary
        case .add:
            let sum = node.inputs.reduce(0.0) { acc, port in
                acc + (port.value?.asDouble() ?? 0)
            }
            node.outputs[safe: 0]??.value = .number(sum)

        case .subtract:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(a - b)

        case .multiply:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(a * b)

        case .divide:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .number(b == 0 ? 0 : a / b)

        case .modulo:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .number(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))

        case .power:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 2
            node.outputs[safe: 0]??.value = .number(pow(a, b))

        case .absolute:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(abs(a))

        case .negate:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(-a)

        // Logic
        case .logicAnd:
            let a = (node.inputs[safe: 0]??.value?.asDouble() ?? 0) != 0
            let b = (node.inputs[safe: 1]??.value?.asDouble() ?? 0) != 0
            node.outputs[safe: 0]??.value = .boolean(a && b)

        case .logicOr:
            let a = (node.inputs[safe: 0]??.value?.asDouble() ?? 0) != 0
            let b = (node.inputs[safe: 1]??.value?.asDouble() ?? 0) != 0
            node.outputs[safe: 0]??.value = .boolean(a || b)

        case .logicNot:
            let a = (node.inputs[safe: 0]??.value?.asDouble() ?? 0) != 0
            node.outputs[safe: 0]??.value = .boolean(!a)

        case .greaterThan:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .boolean(a > b)

        case .lessThan:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .boolean(a < b)

        case .equality:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .boolean(abs(a - b) < 1e-10)

        // Text
        case .concatenate:
            let a = textValue(node.inputs[safe: 0]??.value)
            let b = textValue(node.inputs[safe: 1]??.value)
            node.outputs[safe: 0]??.value = .text(a + b)

        case .textLength:
            let a = textValue(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .number(Double(a.count))

        case .uppercase:
            let a = textValue(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .text(a.uppercased())

        case .lowercase:
            let a = textValue(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .text(a.lowercased())

        // Vector / Point
        case .constructPoint:
            let x = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let y = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let z = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .vector3(x: x, y: y, z: z)

        case .deconstruct:
            if case .vector3(let x, let y, let z) = node.inputs[safe: 0]??.value {
                node.outputs[safe: 0]??.value = .number(x)
                node.outputs[safe: 1]??.value = .number(y)
                node.outputs[safe: 2]??.value = .number(z)
            } else if case .vector2(let p) = node.inputs[safe: 0]??.value {
                node.outputs[safe: 0]??.value = .number(p.x)
                node.outputs[safe: 1]??.value = .number(p.y)
            }

        case .distance:
            if case .vector3(let x1, let y1, let z1) = node.inputs[safe: 0]??.value,
               case .vector3(let x2, let y2, let z2) = node.inputs[safe: 1]??.value {
                let d = sqrt(pow(x2-x1,2) + pow(y2-y1,2) + pow(z2-z1,2))
                node.outputs[safe: 0]??.value = .number(d)
            }

        case .vectorAdd:
            if case .vector3(let x1, let y1, let z1) = node.inputs[safe: 0]??.value,
               case .vector3(let x2, let y2, let z2) = node.inputs[safe: 1]??.value {
                node.outputs[safe: 0]??.value = .vector3(x: x1+x2, y: y1+y2, z: z1+z2)
            }

        case .vectorScale:
            if case .vector3(let x, let y, let z) = node.inputs[safe: 0]??.value {
                let s = node.inputs[safe: 1]??.value?.asDouble() ?? 1
                node.outputs[safe: 0]??.value = .vector3(x: x*s, y: y*s, z: z*s)
            }

        // Utility
        case .output:
            break // just displays

        case .remap:
            let v    = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let low  = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let high = node.inputs[safe: 2]??.value?.asDouble() ?? 1
            let newLow  = node.inputs[safe: 3]??.value?.asDouble() ?? 0
            let newHigh = node.inputs[safe: 4]??.value?.asDouble() ?? 1
            let t = high == low ? 0 : (v - low) / (high - low)
            node.outputs[safe: 0]??.value = .number(newLow + t * (newHigh - newLow))

        case .clamp:
            let v   = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let low = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let high = node.inputs[safe: 2]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .number(min(max(v, low), high))

        case .lerp:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let t = node.inputs[safe: 2]??.value?.asDouble() ?? 0.5
            node.outputs[safe: 0]??.value = .number(a + (b - a) * t)

        case .mergeGeometry:
            let shapes = node.inputs.flatMap { port -> [GeometricShape] in
                guard case .geometry(let shapes) = port.value else { return [] }
                return shapes
            }
            node.outputs[safe: 0]??.value = .geometry(shapes)

        // MARK: Geometry
        case .geoPoint:
            let x = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let y = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let z = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .geometry([.point(Point3D(x: x, y: y, z: z))])

        case .geoLine:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            node.outputs[safe: 0]??.value = .geometry([.line(a, b)])

        case .geoCircle:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            node.outputs[safe: 0]??.value = .geometry([.circle(center: c, radius: r)])

        case .geoPolygon:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = max(0.001, node.inputs[safe: 1]??.value?.asDouble() ?? 5)
            let sides = max(3, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 6))
            let pts = (0..<sides).map { i -> Point3D in
                let a = Double(i) / Double(sides) * 2 * .pi
                return Point3D(x: c.x + r * cos(a), y: c.y + r * sin(a), z: c.z)
            }
            node.outputs[safe: 0]??.value = .geometry([.polygon(pts)])

        case .geoRectangle:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let hw = (node.inputs[safe: 1]??.value?.asDouble() ?? 10) / 2
            let hh = (node.inputs[safe: 2]??.value?.asDouble() ?? 5)  / 2
            let pts = [Point3D(x: c.x-hw, y: c.y-hh, z: c.z),
                       Point3D(x: c.x+hw, y: c.y-hh, z: c.z),
                       Point3D(x: c.x+hw, y: c.y+hh, z: c.z),
                       Point3D(x: c.x-hw, y: c.y+hh, z: c.z)]
            node.outputs[safe: 0]??.value = .geometry([.polygon(pts)])

        case .geoEllipse:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let rx = node.inputs[safe: 1]??.value?.asDouble() ?? 8
            let ry = node.inputs[safe: 2]??.value?.asDouble() ?? 4
            let segs = 64
            let pts = (0...segs).map { i -> Point3D in
                let a = Double(i) / Double(segs) * 2 * .pi
                return Point3D(x: c.x + rx * cos(a), y: c.y + ry * sin(a), z: c.z)
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoArc:
            let c        = vec3(node.inputs[safe: 0]??.value)
            let r        = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let startRad = (node.inputs[safe: 2]??.value?.asDouble() ?? 0)   * .pi / 180
            let endRad   = (node.inputs[safe: 3]??.value?.asDouble() ?? 180) * .pi / 180
            let segs     = max(2, Int(abs(endRad - startRad) / (2 * .pi) * 128) + 1)
            let pts = (0...segs).map { i -> Point3D in
                let a = startRad + Double(i) / Double(segs) * (endRad - startRad)
                return Point3D(x: c.x + r * cos(a), y: c.y + r * sin(a), z: c.z)
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoBezier:
            let p0 = vec3(node.inputs[safe: 0]??.value)
            let p1 = vec3(node.inputs[safe: 1]??.value)
            let p2 = vec3(node.inputs[safe: 2]??.value)
            let p3 = vec3(node.inputs[safe: 3]??.value)
            let segs = 48
            let pts = (0...segs).map { i -> Point3D in
                let t = Double(i) / Double(segs)
                let mt = 1 - t
                let b0 = mt*mt*mt, b1 = 3*mt*mt*t, b2 = 3*mt*t*t, b3 = t*t*t
                return Point3D(x: b0*p0.x + b1*p1.x + b2*p2.x + b3*p3.x,
                               y: b0*p0.y + b1*p1.y + b2*p2.y + b3*p3.y,
                               z: b0*p0.z + b1*p1.z + b2*p2.z + b3*p3.z)
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoBlendArc:
            let p1 = vec3(node.inputs[safe: 0]??.value)
            let p2 = vec3(node.inputs[safe: 2]??.value)
            let segments = max(8, min(256, Int(node.inputs[safe: 4]??.value?.asDouble() ?? 64)))

            let t1 = lineTangent(at: p1, from: node.inputs[safe: 1]??.value)
            let t2 = lineTangent(at: p2, from: node.inputs[safe: 3]??.value)

            guard let t1, let t2 else {
                // Fallback: straight line between the two points
                node.outputs[safe: 0]??.value = .geometry([.line(p1, p2)])
                return
            }

            // Normals to the tangent directions (rotated 90° CCW in XY)
            let n1x = -t1.y; let n1y = t1.x
            let n2x = -t2.y; let n2y = t2.x

            // Vector from P₁ to P₂
            let vx = p2.x - p1.x
            let vy = p2.y - p1.y

            // Intersection of perpendicular lines: p1 + s * n1 = p2 + u * n2
            // s * (n1 × n2) = v × n2   →   s = (v × n2) / (n1 × n2)
            let cross = n1x * n2y - n1y * n2x

            guard abs(cross) > 1e-12 else {
                // Parallel tangents — fallback to straight line
                node.outputs[safe: 0]??.value = .geometry([.line(p1, p2)])
                return
            }

            let s = (vx * n2y - vy * n2x) / cross

            let cx = p1.x + s * n1x
            let cy = p1.y + s * n1y
            let cz = p1.z
            let center = Point3D(x: cx, y: cy, z: cz)
            let r = sqrt(pow(cx - p1.x, 2) + pow(cy - p1.y, 2))

            let startAngle = atan2(p1.y - cy, p1.x - cx)
            let endAngle   = atan2(p2.y - cy, p2.x - cx)

            // Determine sweep direction from tangent alignment
            // CCW tangent at a point on the circle: (-sin(θ), cos(θ))
            let ccwTangentX = -sin(startAngle)
            let ccwTangentY =  cos(startAngle)
            let ccwAgrees = (ccwTangentX * t1.x + ccwTangentY * t1.y) > 0

            var sweep: Double
            if ccwAgrees {
                sweep = endAngle - startAngle
                if sweep < 0 { sweep += 2 * .pi }
            } else {
                sweep = startAngle - endAngle
                if sweep < 0 { sweep += 2 * .pi }
                sweep = -sweep
            }

            let segs = max(8, min(256, Int(abs(sweep) / (2 * .pi) * Double(segments)) + 1))
            let pts: [Point3D] = (0...segs).map { i in
                let a = startAngle + Double(i) / Double(segs) * sweep
                return Point3D(x: cx + r * cos(a), y: cy + r * sin(a), z: cz)
            }

            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoLoftSurface:
            let curveShapes = CurveKernel.allCurves(from: node.inputs[safe: 0]??.value)
            guard curveShapes.count >= 2 else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }

            let sampleCount = max(2, Int(node.inputs[safe: 1]??.value?.asDouble() ?? 24))
            let closedLoft = (node.inputs[safe: 2]??.value?.asDouble() ?? 0) != 0
            var sections = curveShapes.map { CurveKernel.resample(shape: $0, sampleCount: sampleCount) }
            guard sections.allSatisfy({ $0.count == sampleCount }) else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }

            // Every section curve closed (start ≈ end, e.g. circles/closed
            // splines) means the loft should close into a tube across each
            // row too — drop the duplicate wrap point first so gridMesh's
            // own closeU wrap doesn't double it up.
            let tol = 1e-4
            let curvesClosed = sections.allSatisfy { pts in
                guard let first = pts.first, let last = pts.last else { return false }
                return (first - last).length < tol
            }
            if curvesClosed {
                sections = sections.map { Array($0.dropLast()) }
            }

            let md = MeshKernel.loftSurface(sections: sections, closeV: closedLoft, closeU: curvesClosed)
            guard !md.vertices.isEmpty else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        // MARK: 2D Shapes
        case .shape2DPoint:
            let x = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let y = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let thick = max(0.1, node.inputs[safe: 2]??.value?.asDouble() ?? 2)
            let color = node.inputs[safe: 3]??.value?.asColorComponents() ?? (1, 1, 1)
            let style = Shape2DStyle(
                strokeR: color.r, strokeG: color.g, strokeB: color.b,
                strokeThickness: thick,
                fillR: 0, fillG: 0, fillB: 0, fillEnabled: false
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.point(Point3D(x: x, y: y, z: 0)), style)
            ])

        case .shape2DLine:
            let ax = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let ay = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let bx = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            let by = node.inputs[safe: 3]??.value?.asDouble() ?? 10
            let thick = max(0.1, node.inputs[safe: 4]??.value?.asDouble() ?? 2)
            let color = node.inputs[safe: 5]??.value?.asColorComponents() ?? (1, 1, 1)
            let style = Shape2DStyle(
                strokeR: color.r, strokeG: color.g, strokeB: color.b,
                strokeThickness: thick,
                fillR: 0, fillG: 0, fillB: 0, fillEnabled: false
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.line(Point3D(x: ax, y: ay, z: 0),
                                Point3D(x: bx, y: by, z: 0)), style)
            ])

        case .shape2DSquare:
            let cx = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let cy = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let size = max(0.001, node.inputs[safe: 2]??.value?.asDouble() ?? 10)
            let thick = max(0.1, node.inputs[safe: 3]??.value?.asDouble() ?? 2)
            let stroke = node.inputs[safe: 4]??.value?.asColorComponents() ?? (1, 1, 1)
            let fill = node.inputs[safe: 5]??.value?.asColorComponents() ?? (1, 1, 1)
            let fillOn = (node.inputs[safe: 6]??.value?.asDouble() ?? 1) != 0
            let hs = size / 2
            let pts = [Point3D(x: cx-hs, y: cy-hs, z: 0),
                       Point3D(x: cx+hs, y: cy-hs, z: 0),
                       Point3D(x: cx+hs, y: cy+hs, z: 0),
                       Point3D(x: cx-hs, y: cy+hs, z: 0)]
            let style = Shape2DStyle(
                strokeR: stroke.r, strokeG: stroke.g, strokeB: stroke.b,
                strokeThickness: thick,
                fillR: fill.r, fillG: fill.g, fillB: fill.b,
                fillEnabled: fillOn
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.polygon(pts), style)
            ])

        case .shape2DRectangle:
            let cx = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let cy = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let width = max(0.001, node.inputs[safe: 2]??.value?.asDouble() ?? 10)
            let height = max(0.001, node.inputs[safe: 3]??.value?.asDouble() ?? 6)
            let thick = max(0.1, node.inputs[safe: 4]??.value?.asDouble() ?? 2)
            let stroke = node.inputs[safe: 5]??.value?.asColorComponents() ?? (1, 1, 1)
            let fill = node.inputs[safe: 6]??.value?.asColorComponents() ?? (1, 1, 1)
            let fillOn = (node.inputs[safe: 7]??.value?.asDouble() ?? 1) != 0
            let hw = width / 2
            let hh = height / 2
            let pts = [Point3D(x: cx-hw, y: cy-hh, z: 0),
                       Point3D(x: cx+hw, y: cy-hh, z: 0),
                       Point3D(x: cx+hw, y: cy+hh, z: 0),
                       Point3D(x: cx-hw, y: cy+hh, z: 0)]
            let style = Shape2DStyle(
                strokeR: stroke.r, strokeG: stroke.g, strokeB: stroke.b,
                strokeThickness: thick,
                fillR: fill.r, fillG: fill.g, fillB: fill.b,
                fillEnabled: fillOn
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.polygon(pts), style)
            ])

        case .shape2DRectangleCorners:
            let ax = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let ay = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let bx = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            let by = node.inputs[safe: 3]??.value?.asDouble() ?? 6
            let thick = max(0.1, node.inputs[safe: 4]??.value?.asDouble() ?? 2)
            let stroke = node.inputs[safe: 5]??.value?.asColorComponents() ?? (1, 1, 1)
            let fill = node.inputs[safe: 6]??.value?.asColorComponents() ?? (1, 1, 1)
            let fillOn = (node.inputs[safe: 7]??.value?.asDouble() ?? 1) != 0
            let minX = min(ax, bx), maxX = max(ax, bx)
            let minY = min(ay, by), maxY = max(ay, by)
            let pts = [Point3D(x: minX, y: minY, z: 0),
                       Point3D(x: maxX, y: minY, z: 0),
                       Point3D(x: maxX, y: maxY, z: 0),
                       Point3D(x: minX, y: maxY, z: 0)]
            let style = Shape2DStyle(
                strokeR: stroke.r, strokeG: stroke.g, strokeB: stroke.b,
                strokeThickness: thick,
                fillR: fill.r, fillG: fill.g, fillB: fill.b,
                fillEnabled: fillOn
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.polygon(pts), style)
            ])

        case .shape2DSemicircle:
            let p1 = Point3D(x: node.inputs[safe: 0]??.value?.asDouble() ?? 0,
                              y: node.inputs[safe: 1]??.value?.asDouble() ?? 0, z: 0)
            let p2 = Point3D(x: node.inputs[safe: 3]??.value?.asDouble() ?? 10,
                              y: node.inputs[safe: 4]??.value?.asDouble() ?? 0, z: 0)
            let thick = max(0.1, node.inputs[safe: 6]??.value?.asDouble() ?? 2)
            let color = node.inputs[safe: 7]??.value?.asColorComponents() ?? (1, 1, 1)
            let style = Shape2DStyle(
                strokeR: color.r, strokeG: color.g, strokeB: color.b,
                strokeThickness: thick,
                fillR: 0, fillG: 0, fillB: 0, fillEnabled: false
            )

            let chord = p2 - p1
            let diameter = chord.length
            guard diameter > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry([.styled2D(.point(p1), style)])
                return
            }

            // The diameter fixes center and radius exactly — a true semicircle,
            // unlike `.geoBlendArc`, which solves for a variable-radius tangent arc.
            let center = Point3D(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2, z: 0)
            let radius = diameter / 2
            let dir = chord.normalized
            let normal = Point3D(x: -dir.y, y: dir.x, z: 0) // 90° CCW from p1→p2

            // Bulge toward whichever side the incoming line(s) are already heading,
            // so the arc meets them without a kink. A CW sweep (start tangent = +normal)
            // bulges the +normal side; a CCW sweep (start tangent = -normal) bulges -normal.
            let t1 = lineTangent(at: p1, from: node.inputs[safe: 2]??.value)
            let t2 = lineTangent(at: p2, from: node.inputs[safe: 5]??.value)
            var bulgePositive = true
            if let t1 {
                bulgePositive = normal.dot(t1) >= 0
            } else if let t2 {
                bulgePositive = normal.dot(t2) < 0
            }

            let startAngle = atan2(p1.y - center.y, p1.x - center.x)
            let sweep = bulgePositive ? -Double.pi : Double.pi

            let segs = 48
            let pts: [Point3D] = (0...segs).map { i in
                let a = startAngle + Double(i) / Double(segs) * sweep
                return Point3D(x: center.x + radius * cos(a), y: center.y + radius * sin(a), z: 0)
            }
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.polyline(pts), style)
            ])

        case .shape2DEllipse:
            let cx = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let cy = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let rx = max(0.001, node.inputs[safe: 2]??.value?.asDouble() ?? 8)
            let ry = max(0.001, node.inputs[safe: 3]??.value?.asDouble() ?? 5)
            let thick = max(0.1, node.inputs[safe: 4]??.value?.asDouble() ?? 2)
            let stroke = node.inputs[safe: 5]??.value?.asColorComponents() ?? (1, 1, 1)
            let fill = node.inputs[safe: 6]??.value?.asColorComponents() ?? (1, 1, 1)
            let fillOn = (node.inputs[safe: 7]??.value?.asDouble() ?? 1) != 0
            let segs = 64
            let pts = (0...segs).map { i -> Point3D in
                let a = Double(i) / Double(segs) * 2 * .pi
                return Point3D(x: cx + rx * cos(a), y: cy + ry * sin(a), z: 0)
            }
            let style = Shape2DStyle(
                strokeR: stroke.r, strokeG: stroke.g, strokeB: stroke.b,
                strokeThickness: thick,
                fillR: fill.r, fillG: fill.g, fillB: fill.b,
                fillEnabled: fillOn
            )
            node.outputs[safe: 0]??.value = .geometry([
                .styled2D(.polyline(pts), style)
            ])

        case .geoGrid:
            let w    = node.inputs[safe: 0]??.value?.asDouble() ?? 10
            let h    = node.inputs[safe: 1]??.value?.asDouble() ?? 10
            let cols = max(2, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 5))
            let rows = max(2, Int(node.inputs[safe: 3]??.value?.asDouble() ?? 5))
            var shapes: [GeometricShape] = []
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = (Double(c) / Double(cols - 1) - 0.5) * w
                    let y = (Double(r) / Double(rows - 1) - 0.5) * h
                    shapes.append(.point(Point3D(x: x, y: y, z: 0)))
                }
            }
            // Also draw grid lines
            for r in 0..<rows {
                let pts = (0..<cols).map { c -> Point3D in
                    let x = (Double(c) / Double(cols - 1) - 0.5) * w
                    let y = (Double(r) / Double(rows - 1) - 0.5) * h
                    return Point3D(x: x, y: y, z: 0)
                }
                shapes.append(.polyline(pts))
            }
            for c in 0..<cols {
                let pts = (0..<rows).map { r -> Point3D in
                    let x = (Double(c) / Double(cols - 1) - 0.5) * w
                    let y = (Double(r) / Double(rows - 1) - 0.5) * h
                    return Point3D(x: x, y: y, z: 0)
                }
                shapes.append(.polyline(pts))
            }
            node.outputs[safe: 0]??.value = .geometry(shapes)

        case .geoSphere:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            node.outputs[safe: 0]??.value = .geometry([.sphere(center: c, radius: r)])

        case .geoBox:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let hw = (node.inputs[safe: 1]??.value?.asDouble() ?? 10) / 2
            let hh = (node.inputs[safe: 2]??.value?.asDouble() ?? 10) / 2
            let hd = (node.inputs[safe: 3]??.value?.asDouble() ?? 10) / 2
            node.outputs[safe: 0]??.value = .geometry([
                .box(Point3D(x: c.x-hw, y: c.y-hh, z: c.z-hd),
                     Point3D(x: c.x+hw, y: c.y+hh, z: c.z+hd))
            ])

        case .geoCylinder:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let h = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .geometry([.cylinder(center: c, radius: r, height: h)])

        case .geoCone:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let h = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .geometry([.cone(center: c, radius: r, height: h)])

        case .geoTorus:
            let c    = vec3(node.inputs[safe: 0]??.value)
            let majR = node.inputs[safe: 1]??.value?.asDouble() ?? 8
            let minR = node.inputs[safe: 2]??.value?.asDouble() ?? 2
            node.outputs[safe: 0]??.value = .geometry([.torus(center: c, majorRadius: majR, minorRadius: minR)])

        case .material:
            // Rough/Metal/Spec/Coat/Bump/Var/Aniso ports accept a plain
            // 0...100 range (see NodeFactory) so an out-of-the-box Number
            // Slider's default domain is directly usable; rescale to the
            // internal 0...1 factor here.
            func pct(_ index: Int, default def100: Double) -> Double {
                let raw = node.inputs[safe: index]??.value?.asDouble() ?? def100
                return max(0, min(1, raw / 100))
            }
            let color = node.inputs[safe: 0]??.value?.asColorComponentsRGBA()
            let r     = color?.r ?? 0.72
            let g     = color?.g ?? 0.72
            let b     = color?.b ?? 0.78
            let rough = pct(1, default: 35)
            let metal = pct(2, default: 0)
            let specular = pct(3, default: 55)
            let clearcoat = pct(4, default: 10)
            let normal = pct(5, default: 22)
            let textureScale = max(0.1, min(24, node.inputs[safe: 6]??.value?.asDouble() ?? 1.0))
            let roughnessVariation = pct(7, default: 16)
            let anisotropy = pct(8, default: 0)
            let surfaceType = textValue(node.inputs[safe: 9]??.value)
            let finish = textValue(node.inputs[safe: 10]??.value)
            let pattern = textValue(node.inputs[safe: 11]??.value)
            let sheenColor = node.inputs[safe: 12]??.value?.asColorComponentsRGBA()
            let sheenRoughness = pct(13, default: 30)
            let transmission = pct(14, default: 0)
            // IOR: 0...200 slider rescaled to 1.0...3.0 — unlike the other
            // fields above this needs a >1 range, so it doesn't use pct().
            let iorRaw = max(0, min(200, node.inputs[safe: 15]??.value?.asDouble() ?? 50))
            let ior = 1.0 + iorRaw / 100
            let emissionColor = node.inputs[safe: 16]??.value?.asColorComponentsRGBA()
            let emissionStrength = max(0, node.inputs[safe: 17]??.value?.asDouble() ?? 0)
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: r,
                    g: g,
                    b: b,
                    roughness: rough,
                    metalness: metal,
                    specular: specular,
                    clearcoat: clearcoat,
                    normal: normal,
                    textureScale: textureScale,
                    roughnessVariation: roughnessVariation,
                    anisotropy: anisotropy,
                    surfaceType: surfaceType,
                    finish: finish,
                    roughnessPattern: pattern,
                    sheenR: sheenColor?.r ?? 0,
                    sheenG: sheenColor?.g ?? 0,
                    sheenB: sheenColor?.b ?? 0,
                    sheenRoughness: sheenRoughness,
                    transmission: transmission,
                    ior: ior,
                    emissionR: emissionColor?.r ?? 0,
                    emissionG: emissionColor?.g ?? 0,
                    emissionB: emissionColor?.b ?? 0,
                    emissionStrength: emissionStrength
                )
            )

        case .materialABSPlastic:
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.10, g: 0.11, b: 0.12,
                    roughness: 0.40,
                    metalness: 0.0,
                    specular: 0.54,
                    clearcoat: 0.16,
                    normal: 0.12,
                    textureScale: 1.0,
                    roughnessVariation: 0.14,
                    anisotropy: 0.0,
                    surfaceType: "plastic",
                    finish: "satin",
                    roughnessPattern: "orange-peel"
                )
            )

        case .materialAnodizedAluminum:
            // baseColor doubles as F0 for a metal — this is measured
            // aluminum reflectance (Hoffman/Frostbite "common F0 values"
            // table), not an artistic guess. Aluminum is a genuinely
            // near-neutral reflector (that's *why* it reads as silvery),
            // with just the faintest warm-to-cool lean vs. pure white.
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.91, g: 0.92, b: 0.92,
                    roughness: 0.18,
                    metalness: 0.94,
                    specular: 0.78,
                    clearcoat: 0.02,
                    normal: 0.10,
                    textureScale: 1.9,
                    roughnessVariation: 0.08,
                    anisotropy: 0.42,
                    surfaceType: "metal",
                    finish: "anodized",
                    roughnessPattern: "machined"
                )
            )

        case .materialBrushedStainless:
            // Stainless is an iron/chromium/nickel alloy; F0 approximated
            // from iron's measured reflectance with a touch of nickel's
            // warmth — real steel is a fairly dark, faintly warm reflector
            // at normal incidence, not a bright silver (the bright look
            // comes from the mirror-sharp Fresnel edge, not from F0 itself).
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.63, g: 0.61, b: 0.57,
                    roughness: 0.24,
                    metalness: 0.98,
                    specular: 0.84,
                    clearcoat: 0.0,
                    normal: 0.14,
                    textureScale: 2.6,
                    roughnessVariation: 0.10,
                    anisotropy: 0.72,
                    surfaceType: "metal",
                    finish: "brushed",
                    roughnessPattern: "brushed"
                )
            )

        case .materialBeadBlastedSteel:
            // Measured iron reflectance — same alloy family as the brushed
            // preset above, cooler/more neutral than the warm-leaning steel
            // blend used there.
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.56, g: 0.57, b: 0.58,
                    roughness: 0.62,
                    metalness: 0.96,
                    specular: 0.70,
                    clearcoat: 0.0,
                    normal: 0.20,
                    textureScale: 1.5,
                    roughnessVariation: 0.18,
                    anisotropy: 0.06,
                    surfaceType: "metal",
                    finish: "bead-blasted",
                    roughnessPattern: "stippled"
                )
            )

        case .materialChrome:
            // Measured chromium reflectance. Counter-intuitively dark/
            // desaturated at normal incidence — chrome's "bright mirror"
            // look comes from its very low roughness (sharp, undiffused
            // reflections) and strong Fresnel brightening at grazing
            // angles, not from F0 itself being high.
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.55, g: 0.56, b: 0.55,
                    roughness: 0.05,
                    metalness: 1.0,
                    specular: 0.96,
                    clearcoat: 0.0,
                    normal: 0.04,
                    textureScale: 2.2,
                    roughnessVariation: 0.03,
                    anisotropy: 0.08,
                    surfaceType: "metal",
                    finish: "polished",
                    roughnessPattern: "smooth"
                )
            )

        case .materialVelvet:
            // Deep-dyed cotton/silk velvet: low reflectance dielectric base
            // (fabric absorbs most direct specular) plus a strong, broad
            // sheen lobe — the soft "glow" along grazing angles that reads
            // as fuzz — tinted slightly warm the way pile fabric catches
            // light unevenly against the weave direction.
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.14, g: 0.03, b: 0.08,
                    roughness: 0.85,
                    metalness: 0.0,
                    specular: 0.05,
                    clearcoat: 0.0,
                    normal: 0.30,
                    textureScale: 3.2,
                    roughnessVariation: 0.20,
                    anisotropy: 0.0,
                    surfaceType: "plastic",
                    finish: "matte",
                    roughnessPattern: "stippled",
                    sheenR: 0.55, sheenG: 0.30, sheenB: 0.38,
                    sheenRoughness: 0.55
                )
            )

        case .materialWax:
            // Candle wax / alabaster: subsurface shading model — light enters
            // and re-exits some distance away rather than bouncing straight
            // off, which is what actually reads as "translucent" instead of
            // just "glossy white plastic". subsurfaceColor here is warmer
            // than baseColor, matching how wax looks redder/more amber when
            // backlit than it does in reflected light.
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.93, g: 0.90, b: 0.83,
                    roughness: 0.35,
                    metalness: 0.0,
                    specular: 0.4,
                    normal: 0.08,
                    textureScale: 1.3,
                    roughnessVariation: 0.06,
                    surfaceType: "plastic",
                    finish: "satin",
                    roughnessPattern: "orange-peel",
                    shadingFamily: "subsurface",
                    subsurfaceR: 0.95, subsurfaceG: 0.55, subsurfaceB: 0.25,
                    subsurfacePower: 8.0,
                    thickness: 0.6
                )
            )

        case .sceneLighting:
            let sunX = node.inputs[safe: 0]??.value?.asDouble() ?? -0.55
            let sunY = node.inputs[safe: 1]??.value?.asDouble() ?? -0.72
            let sunZ = node.inputs[safe: 2]??.value?.asDouble() ?? 0.41
            let sunColor = node.inputs[safe: 3]??.value?.asColorComponents()
            let sunIntensity = max(0, node.inputs[safe: 4]??.value?.asDouble() ?? 80_000)
            let exposure = node.inputs[safe: 5]??.value?.asDouble() ?? 0
            // Contrast/Saturation accept 0...100 (50 = neutral); rescale to
            // the internal -1...1 factor, same reasoning as the Material
            // node's percentage-style inputs.
            let contrastRaw = node.inputs[safe: 6]??.value?.asDouble() ?? 50
            let saturationRaw = node.inputs[safe: 7]??.value?.asDouble() ?? 50
            let contrast = max(-1, min(1, (contrastRaw - 50) / 50))
            let saturation = max(-1, min(1, (saturationRaw - 50) / 50))
            let whiteBalance = max(1000, min(20_000, node.inputs[safe: 8]??.value?.asDouble() ?? 6500))
            let toneMapText = textValue(node.inputs[safe: 9]??.value)

            var config = RenderConfig.cinematicDefault
            config.sunDirection = Point3D(x: sunX, y: sunY, z: sunZ)
            config.sunColor = ColorRGB(sunColor?.r ?? 1.0, sunColor?.g ?? 0.95, sunColor?.b ?? 0.88)
            config.sunIntensity = sunIntensity
            config.exposure = exposure
            config.contrast = contrast
            config.saturation = saturation
            config.whiteBalanceKelvin = whiteBalance
            config.toneMapper = ToneMapper.parse(toneMapText)
            node.outputs[safe: 0]??.value = .renderConfig(config)

        case .pointLight:
            var config: RenderConfig
            if case .renderConfig(let base) = node.inputs[safe: 3]??.value {
                config = base
            } else {
                // Nothing wired into Env: this is the root of the lighting
                // chain, so its light(s) replace the default sun rather than
                // adding to it. (Chain in a Scene Lighting node's Env output
                // if you want the sun to stay on alongside this light.)
                config = .cinematicDefault
                config.sunIntensity = 0
            }

            var position = Point3D(x: 0, y: 0, z: 5)
            if case .vector3(let x, let y, let z) = node.inputs[safe: 0]??.value {
                position = Point3D(x: x, y: y, z: z)
            }

            let colorComponents = node.inputs[safe: 1]??.value?.asColorComponents()
            let color = ColorRGB(colorComponents?.r ?? 1.0, colorComponents?.g ?? 1.0, colorComponents?.b ?? 1.0)
            let strength = max(0, node.inputs[safe: 2]??.value?.asDouble() ?? 1000)

            config.pointLights.append(SceneLight(position: position, color: color, intensity: strength))
            node.outputs[safe: 0]??.value = .renderConfig(config)

        case .objectLight:
            var config: RenderConfig
            if case .renderConfig(let base) = node.inputs[safe: 3]??.value {
                config = base
            } else {
                // Same "root of the chain replaces the sun" behavior as
                // Point Light above.
                config = .cinematicDefault
                config.sunIntensity = 0
            }

            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value, !shapes.isEmpty else {
                node.outputs[safe: 0]??.value = .renderConfig(config)
                return
            }

            let colorComponents = node.inputs[safe: 1]??.value?.asColorComponents()
            let color = ColorRGB(colorComponents?.r ?? 1.0, colorComponents?.g ?? 1.0, colorComponents?.b ?? 1.0)
            let strength = max(0, node.inputs[safe: 2]??.value?.asDouble() ?? 20)

            config.objectLights.append(SceneObjectLight(shapes: shapes, color: color, intensity: strength))
            node.outputs[safe: 0]??.value = .renderConfig(config)

        case .volumetricFog:
            var fogConfig: RenderConfig
            if case .renderConfig(let base) = node.inputs[safe: 5]??.value {
                fogConfig = base
            } else {
                fogConfig = .cinematicDefault
            }

            var enabled = true
            if case .boolean(let b) = node.inputs[safe: 0]??.value { enabled = b }
            let density = max(0, min(100, node.inputs[safe: 1]??.value?.asDouble() ?? 20)) / 1000
            let colorComponents = node.inputs[safe: 2]??.value?.asColorComponentsRGBA()
            // Anisotropy accepts 0...100 (50 = neutral/isotropic); rescale to
            // the internal -1...1 Henyey-Greenstein `g` factor, same
            // reasoning as the Material node's percentage-style inputs.
            let anisotropyRaw = node.inputs[safe: 3]??.value?.asDouble() ?? 50
            let anisotropy = max(-1, min(1, (anisotropyRaw - 50) / 50))
            let heightFalloff = max(0, node.inputs[safe: 4]??.value?.asDouble() ?? 0)

            fogConfig.pathTracerVolume = PTVolumeConfig(
                enabled: enabled,
                density: density,
                colorR: colorComponents?.r ?? 1.0,
                colorG: colorComponents?.g ?? 1.0,
                colorB: colorComponents?.b ?? 1.0,
                anisotropy: anisotropy,
                heightFalloff: heightFalloff
            )
            node.outputs[safe: 0]??.value = .renderConfig(fogConfig)

        case .geoTranslate:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let tx = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let ty = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            let tz = node.inputs[safe: 3]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .geometry(shapes.map { $0.translated(dx: tx, dy: ty, dz: tz) })

        case .geoRotate:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let deg = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let ax  = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            let ay  = node.inputs[safe: 3]??.value?.asDouble() ?? 0
            let az  = node.inputs[safe: 4]??.value?.asDouble() ?? 1
            let axis = Point3D(x: ax, y: ay, z: az)
            node.outputs[safe: 0]??.value = .geometry(shapes.map { $0.rotated(angle: deg * .pi / 180, axis: axis) })

        case .geoScale:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let f = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .geometry(shapes.map { $0.scaled(by: f) })

        // MARK: Vector – Planes
        case .constructPlane:
            let origin = vec3(node.inputs[safe: 0]??.value)
            let normalIn = vec3(node.inputs[safe: 1]??.value)
            let xAxisIn = vec3(node.inputs[safe: 2]??.value)
            let normal = normalIn.length > 1e-9 ? normalIn.normalized : Point3D(x: 0, y: 0, z: 1)
            let xAxis = xAxisIn.length > 1e-9 ? xAxisIn.normalized : Point3D(x: 1, y: 0, z: 0)
            node.outputs[safe: 0]??.value = .plane(origin: origin, normal: normal, xAxis: xAxis)

        case .deconstructPlane:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .vector3(x: pl.origin.x, y: pl.origin.y, z: pl.origin.z)
            node.outputs[safe: 1]??.value = .vector3(x: pl.normal.x, y: pl.normal.y, z: pl.normal.z)
            node.outputs[safe: 2]??.value = .vector3(x: pl.xAxis.x, y: pl.xAxis.y, z: pl.xAxis.z)

        case .planeXY:
            node.outputs[safe: 0]??.value = .plane(origin: .zero, normal: Point3D(x: 0, y: 0, z: 1), xAxis: Point3D(x: 1, y: 0, z: 0))

        case .planeYZ:
            node.outputs[safe: 0]??.value = .plane(origin: .zero, normal: Point3D(x: 1, y: 0, z: 0), xAxis: Point3D(x: 0, y: 1, z: 0))

        case .planeZX:
            node.outputs[safe: 0]??.value = .plane(origin: .zero, normal: Point3D(x: 0, y: 1, z: 0), xAxis: Point3D(x: 0, y: 0, z: 1))

        // MARK: Transform
        case .geoScaleNU:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let fx = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let fy = node.inputs[safe: 2]??.value?.asDouble() ?? 1
            let fz = node.inputs[safe: 3]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .geometry(shapes.map { $0.mapped { Point3D(x: $0.x * fx, y: $0.y * fy, z: $0.z * fz) } })

        case .geoMirror:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let pl = planeValue(node.inputs[safe: 1]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            node.outputs[safe: 0]??.value = .geometry(shapes.map { shape in
                shape.mapped { p in
                    let d = (p - pl.origin).dot(n)
                    return p - n.scaled(by: 2 * d)
                }
            })

        case .geoArrayLinear:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let dir = Point3D(x: node.inputs[safe: 1]??.value?.asDouble() ?? 1,
                               y: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                               z: node.inputs[safe: 3]??.value?.asDouble() ?? 0)
            let count = max(1, Int(node.inputs[safe: 4]??.value?.asDouble() ?? 5))
            let spacing = node.inputs[safe: 5]??.value?.asDouble() ?? 5
            let unit = dir.length > 1e-9 ? dir.normalized : Point3D(x: 1, y: 0, z: 0)
            var result: [GeometricShape] = []
            for i in 0..<count {
                let offset = unit.scaled(by: Double(i) * spacing)
                result.append(contentsOf: shapes.map { $0.translated(dx: offset.x, dy: offset.y, dz: offset.z) })
            }
            node.outputs[safe: 0]??.value = .geometry(result)

        case .geoArrayPolar:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let center = Point3D(x: node.inputs[safe: 1]??.value?.asDouble() ?? 0,
                                  y: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                                  z: node.inputs[safe: 3]??.value?.asDouble() ?? 0)
            let axis = Point3D(x: node.inputs[safe: 4]??.value?.asDouble() ?? 0,
                                y: node.inputs[safe: 5]??.value?.asDouble() ?? 0,
                                z: node.inputs[safe: 6]??.value?.asDouble() ?? 1)
            let count = max(1, Int(node.inputs[safe: 7]??.value?.asDouble() ?? 8))
            let totalDeg = node.inputs[safe: 8]??.value?.asDouble() ?? 360
            let unitAxis = axis.length > 1e-9 ? axis.normalized : Point3D(x: 0, y: 0, z: 1)
            var result: [GeometricShape] = []
            for i in 0..<count {
                let angle = (totalDeg / Double(count)) * Double(i) * .pi / 180
                result.append(contentsOf: shapes.map { shape in
                    shape.mapped { p in center + (p - center).rotated(angle: angle, axis: unitAxis) }
                })
            }
            node.outputs[safe: 0]??.value = .geometry(result)

        case .geoOrient:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let from = planeValue(node.inputs[safe: 1]??.value)
            let to = planeValue(node.inputs[safe: 2]??.value)
            let fromN = from.normal.length > 1e-9 ? from.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let fromX = from.xAxis.length > 1e-9 ? from.xAxis.normalized : Point3D(x: 1, y: 0, z: 0)
            let fromY = fromN.cross(fromX).normalized
            let toN = to.normal.length > 1e-9 ? to.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let toX = to.xAxis.length > 1e-9 ? to.xAxis.normalized : Point3D(x: 1, y: 0, z: 0)
            let toY = toN.cross(toX).normalized
            node.outputs[safe: 0]??.value = .geometry(shapes.map { shape in
                shape.mapped { p in
                    let rel = p - from.origin
                    let u = rel.dot(fromX), v = rel.dot(fromY), w = rel.dot(fromN)
                    return to.origin + toX.scaled(by: u) + toY.scaled(by: v) + toN.scaled(by: w)
                }
            })

        // MARK: Curve
        case .curveDivide:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let count = max(2, Int(node.inputs[safe: 1]??.value?.asDouble() ?? 10))
            let pts = CurveKernel.divide(CurveKernel.polylinePoints(for: curve), count: count)
            node.outputs[safe: 0]??.value = .geometry(pts.map { .point($0) })

        case .curveLength:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .number(CurveKernel.length(of: CurveKernel.polylinePoints(for: curve)))

        case .curvePointAt:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let t = node.inputs[safe: 1]??.value?.asDouble() ?? 0.5
            let p = CurveKernel.pointAt(CurveKernel.polylinePoints(for: curve), t: t)
            node.outputs[safe: 0]??.value = .vector3(x: p.x, y: p.y, z: p.z)

        case .curveEndPoints:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value),
                  let ends = CurveKernel.endPoints(CurveKernel.polylinePoints(for: curve)) else { return }
            node.outputs[safe: 0]??.value = .vector3(x: ends.start.x, y: ends.start.y, z: ends.start.z)
            node.outputs[safe: 1]??.value = .vector3(x: ends.end.x, y: ends.end.y, z: ends.end.z)

        case .curveExtend:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let startLen = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let endLen = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            let pts = CurveKernel.extend(CurveKernel.polylinePoints(for: curve), startLength: startLen, endLength: endLen)
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .curveOffset:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let dist = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let pts = CurveKernel.offset(CurveKernel.polylinePoints(for: curve), distance: dist)
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .curveFillet:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let radius = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let pts = CurveKernel.filletPolygon(CurveKernel.polylinePoints(for: curve), radius: radius)
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .curveInterpolate:
            let pts = pointList(from: node.inputs[safe: 0]??.value)
            guard pts.count >= 2 else { node.outputs[safe: 0]??.value = .geometry([]); return }
            let degree = max(1, Int(node.inputs[safe: 1]??.value?.asDouble() ?? 3))
            let closed = (node.inputs[safe: 2]??.value?.asDouble() ?? 0) != 0
            let (cps, actualDegree) = CurveKernel.interpolatedSpline(through: pts, degree: degree, closed: closed)
            node.outputs[safe: 0]??.value = .geometry([.spline(controlPoints: cps, degree: actualDegree, closed: false)])

        case .curveClosestPoint:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let test = vec3(node.inputs[safe: 1]??.value)
            let result = CurveKernel.closestPoint(CurveKernel.polylinePoints(for: curve), to: test)
            node.outputs[safe: 0]??.value = .vector3(x: result.point.x, y: result.point.y, z: result.point.z)
            node.outputs[safe: 1]??.value = .number(result.t)
            node.outputs[safe: 2]??.value = .number(result.distance)

        case .curveCurveIntersect:
            guard let curveA = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value),
                  let curveB = CurveKernel.firstCurve(from: node.inputs[safe: 1]??.value) else { return }
            let hits = CurveKernel.intersectXY(CurveKernel.polylinePoints(for: curveA), CurveKernel.polylinePoints(for: curveB))
            node.outputs[safe: 0]??.value = .geometry(hits.map { .point($0) })

        // MARK: Surface
        case .surfaceExtrude:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let dir = Point3D(x: node.inputs[safe: 1]??.value?.asDouble() ?? 0,
                               y: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                               z: node.inputs[safe: 3]??.value?.asDouble() ?? 5)
            let cap = (node.inputs[safe: 4]??.value?.asDouble() ?? 1) != 0
            let md = MeshKernel.extrude(profile: CurveKernel.polylinePoints(for: curve), direction: dir, capped: cap)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        case .surfaceExtrudePoint:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let apex = vec3(node.inputs[safe: 1]??.value)
            let cap = (node.inputs[safe: 2]??.value?.asDouble() ?? 1) != 0
            let md = MeshKernel.extrudeToPoint(profile: CurveKernel.polylinePoints(for: curve), apex: apex, capped: cap)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        case .surfaceRevolve:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let axisOrigin = vec3(node.inputs[safe: 1]??.value)
            let axisDir = Point3D(x: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                                   y: node.inputs[safe: 3]??.value?.asDouble() ?? 0,
                                   z: node.inputs[safe: 4]??.value?.asDouble() ?? 1)
            let angle = node.inputs[safe: 5]??.value?.asDouble() ?? 360
            let segs = max(3, Int(node.inputs[safe: 6]??.value?.asDouble() ?? 32))
            let md = MeshKernel.revolve(profile: CurveKernel.polylinePoints(for: curve), axisOrigin: axisOrigin,
                                         axisDir: axisDir, angleDegrees: angle, segments: segs)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        case .surfaceSweep1:
            guard let profileCurve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value),
                  let railCurve = CurveKernel.firstCurve(from: node.inputs[safe: 1]??.value) else { return }
            let md = MeshKernel.sweep1(profile: CurveKernel.polylinePoints(for: profileCurve),
                                        rail: CurveKernel.polylinePoints(for: railCurve), capped: true)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        case .surfaceBoundary:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let md = MeshKernel.boundarySurface(profile: CurveKernel.polylinePoints(for: curve))
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        case .surfaceOffset:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let dist = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let offsetMesh = MeshKernel.offset(md, distance: dist)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: offsetMesh.vertices, triangleIndices: offsetMesh.triangleIndices)])

        case .surfacePipe:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let radius = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let segs = max(6, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 16))
            let cap = (node.inputs[safe: 3]??.value?.asDouble() ?? 1) != 0
            let md = MeshKernel.pipe(rail: CurveKernel.polylinePoints(for: curve), radius: radius, segments: segs, capped: cap)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)])

        // MARK: Solid
        case .solidUnion:
            guard let a = firstMeshData(node.inputs[safe: 0]??.value), let b = firstMeshData(node.inputs[safe: 1]??.value) else { return }
            let result = CSGKernel.union(a, b)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: result.vertices, triangleIndices: result.triangleIndices)])

        case .solidDifference:
            guard let a = firstMeshData(node.inputs[safe: 0]??.value), let b = firstMeshData(node.inputs[safe: 1]??.value) else { return }
            let result = CSGKernel.subtract(a, b)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: result.vertices, triangleIndices: result.triangleIndices)])

        case .solidIntersection:
            guard let a = firstMeshData(node.inputs[safe: 0]??.value), let b = firstMeshData(node.inputs[safe: 1]??.value) else { return }
            let result = CSGKernel.intersect(a, b)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: result.vertices, triangleIndices: result.triangleIndices)])

        case .solidCapHoles:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let capped = MeshKernel.capHoles(md)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: capped.vertices, triangleIndices: capped.triangleIndices)])

        case .solidBoundingBox:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value,
                  let bbox = MeshKernel.boundingBox(of: shapes) else { return }
            node.outputs[safe: 0]??.value = .geometry([.box(bbox.min, bbox.max)])
            node.outputs[safe: 1]??.value = .number(bbox.max.x - bbox.min.x)
            node.outputs[safe: 2]??.value = .number(bbox.max.y - bbox.min.y)
            node.outputs[safe: 3]??.value = .number(bbox.max.z - bbox.min.z)

        case .solidVolume:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .number(MeshKernel.volume(of: md))

        case .solidCentroid:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let c = MeshKernel.centroid(of: md)
            node.outputs[safe: 0]??.value = .vector3(x: c.x, y: c.y, z: c.z)

        // MARK: Intersect
        case .meshPlaneSection:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let pl = planeValue(node.inputs[safe: 1]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let segments = meshPlaneCrossSections(md, planeOrigin: pl.origin, planeNormal: n)
            node.outputs[safe: 0]??.value = .geometry(segments.map { .line($0.0, $0.1) })

        case .lineLineIntersect:
            guard let lineA = firstLineEndpoints(node.inputs[safe: 0]??.value),
                  let lineB = firstLineEndpoints(node.inputs[safe: 1]??.value) else { return }
            let result = CurveKernel.lineLineClosest(lineA.0, lineA.1, lineB.0, lineB.1)
            node.outputs[safe: 0]??.value = .vector3(x: result.point.x, y: result.point.y, z: result.point.z)
            node.outputs[safe: 1]??.value = .boolean(result.didIntersect)

        case .planePlaneIntersect:
            let plA = planeValue(node.inputs[safe: 0]??.value)
            let plB = planeValue(node.inputs[safe: 1]??.value)
            let n1 = plA.normal.length > 1e-9 ? plA.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let n2 = plB.normal.length > 1e-9 ? plB.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let dir = n1.cross(n2)
            guard dir.length > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry([])
                node.outputs[safe: 1]??.value = .boolean(false)
                return
            }
            let dirN = dir.normalized
            let d1 = n1.dot(plA.origin)
            let d2 = n2.dot(plB.origin)
            let n1n2 = n1.dot(n2)
            let det = 1 - n1n2 * n1n2
            guard abs(det) > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry([])
                node.outputs[safe: 1]??.value = .boolean(false)
                return
            }
            let c1 = (d1 - d2 * n1n2) / det
            let c2 = (d2 - d1 * n1n2) / det
            let point = n1.scaled(by: c1) + n2.scaled(by: c2)
            let half = 50.0
            node.outputs[safe: 0]??.value = .geometry([.line(point - dirN.scaled(by: half), point + dirN.scaled(by: half))])
            node.outputs[safe: 1]??.value = .boolean(true)

        case .planeLineIntersect:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            guard let (a, b) = firstLineEndpoints(node.inputs[safe: 1]??.value) else { return }
            let d = b - a
            let denom = n.dot(d)
            guard abs(denom) > 1e-9 else {
                node.outputs[safe: 1]??.value = .boolean(false)
                return
            }
            let t = n.dot(pl.origin - a) / denom
            let pt = a + d.scaled(by: t)
            node.outputs[safe: 0]??.value = .vector3(x: pt.x, y: pt.y, z: pt.z)
            node.outputs[safe: 1]??.value = .boolean(true)

        case .pointPlaneDistance:
            let p = vec3(node.inputs[safe: 0]??.value)
            let pl = planeValue(node.inputs[safe: 1]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            node.outputs[safe: 0]??.value = .number((p - pl.origin).dot(n))

        // MARK: Vector (additions)
        case .vectorTwoPt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let r = b - a
            node.outputs[safe: 0]??.value = .vector3(x: r.x, y: r.y, z: r.z)

        case .vectorUnitize:
            let v = vec3(node.inputs[safe: 0]??.value)
            let u = v.length > 1e-9 ? v.normalized : v
            node.outputs[safe: 0]??.value = .vector3(x: u.x, y: u.y, z: u.z)

        case .vectorLength:
            node.outputs[safe: 0]??.value = .number(vec3(node.inputs[safe: 0]??.value).length)

        case .vectorReverse:
            let v = vec3(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .vector3(x: -v.x, y: -v.y, z: -v.z)

        case .vectorCrossProduct:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let r = a.cross(b)
            node.outputs[safe: 0]??.value = .vector3(x: r.x, y: r.y, z: r.z)

        case .vectorDotProduct:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            node.outputs[safe: 0]??.value = .number(a.dot(b))

        case .vectorRotate:
            let v = vec3(node.inputs[safe: 0]??.value)
            let deg = node.inputs[safe: 1]??.value?.asDouble() ?? 90
            let axisIn = vec3(node.inputs[safe: 2]??.value)
            let axis = axisIn.length > 1e-9 ? axisIn.normalized : Point3D(x: 0, y: 0, z: 1)
            let r = v.rotated(angle: deg * .pi / 180, axis: axis)
            node.outputs[safe: 0]??.value = .vector3(x: r.x, y: r.y, z: r.z)

        case .vectorAngle:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            guard a.length > 1e-9, b.length > 1e-9 else {
                node.outputs[safe: 0]??.value = .number(0)
                return
            }
            let cosA = max(-1, min(1, a.dot(b) / (a.length * b.length)))
            node.outputs[safe: 0]??.value = .number(acos(cosA) * 180 / .pi)

        // MARK: Point (additions)
        case .pointOnPlane:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            let (xAxis, yAxis) = planeBasis(pl)
            let u = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let v = node.inputs[safe: 2]??.value?.asDouble() ?? 0
            let p = pl.origin + xAxis.scaled(by: u) + yAxis.scaled(by: v)
            node.outputs[safe: 0]??.value = .vector3(x: p.x, y: p.y, z: p.z)

        case .pointPolar:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            let (xAxis, yAxis) = planeBasis(pl)
            let deg = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let r = node.inputs[safe: 2]??.value?.asDouble() ?? 5
            let rad = deg * .pi / 180
            let p = pl.origin + xAxis.scaled(by: r * cos(rad)) + yAxis.scaled(by: r * sin(rad))
            node.outputs[safe: 0]??.value = .vector3(x: p.x, y: p.y, z: p.z)

        case .pointCylindrical:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            let (xAxis, yAxis) = planeBasis(pl)
            let normal = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let deg = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let r = node.inputs[safe: 2]??.value?.asDouble() ?? 5
            let z = node.inputs[safe: 3]??.value?.asDouble() ?? 0
            let rad = deg * .pi / 180
            let p = pl.origin + xAxis.scaled(by: r * cos(rad)) + yAxis.scaled(by: r * sin(rad)) + normal.scaled(by: z)
            node.outputs[safe: 0]??.value = .vector3(x: p.x, y: p.y, z: p.z)

        case .constructPointPolar:
            let origin = vec3(node.inputs[safe: 0]??.value)
            let deg = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            let r = node.inputs[safe: 2]??.value?.asDouble() ?? 5
            let rad = deg * .pi / 180
            node.outputs[safe: 0]??.value = .vector3(x: origin.x + r * cos(rad), y: origin.y + r * sin(rad), z: origin.z)

        case .projectPointToPlane:
            let p = vec3(node.inputs[safe: 0]??.value)
            let pl = planeValue(node.inputs[safe: 1]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let result = p - n.scaled(by: (p - pl.origin).dot(n))
            node.outputs[safe: 0]??.value = .vector3(x: result.x, y: result.y, z: result.z)

        case .populate3D:
            let center = vec3(node.inputs[safe: 0]??.value)
            let sx = node.inputs[safe: 1]??.value?.asDouble() ?? 10
            let sy = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            let sz = node.inputs[safe: 3]??.value?.asDouble() ?? 10
            let count = max(0, Int(node.inputs[safe: 4]??.value?.asDouble() ?? 20))
            let seed = UInt64(bitPattern: Int64(node.inputs[safe: 5]??.value?.asDouble() ?? 0))
            var rng = SeededRandomGenerator(seed: seed)
            let pts: [GeometricShape] = (0..<count).map { _ in
                let x = center.x + (Double.random(in: -0.5...0.5, using: &rng)) * sx
                let y = center.y + (Double.random(in: -0.5...0.5, using: &rng)) * sy
                let z = center.z + (Double.random(in: -0.5...0.5, using: &rng)) * sz
                return .point(Point3D(x: x, y: y, z: z))
            }
            node.outputs[safe: 0]??.value = .geometry(pts)

        // MARK: Plane (additions)
        case .planeThreePt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let c = vec3(node.inputs[safe: 2]??.value)
            let xAxisRaw = b - a
            let xAxis = xAxisRaw.length > 1e-9 ? xAxisRaw.normalized : Point3D(x: 1, y: 0, z: 0)
            let normalRaw = xAxis.cross(c - a)
            let normal = normalRaw.length > 1e-9 ? normalRaw.normalized : Point3D(x: 0, y: 0, z: 1)
            node.outputs[safe: 0]??.value = .plane(origin: a, normal: normal, xAxis: xAxis)

        case .planeFlip:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            node.outputs[safe: 0]??.value = .plane(
                origin: pl.origin,
                normal: Point3D(x: -pl.normal.x, y: -pl.normal.y, z: -pl.normal.z),
                xAxis: pl.xAxis
            )

        // MARK: Transform (additions)
        case .geoProject:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let pl = planeValue(node.inputs[safe: 1]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            node.outputs[safe: 0]??.value = .geometry(shapes.map { shape in
                shape.mapped { p in p - n.scaled(by: (p - pl.origin).dot(n)) }
            })

        case .geoTwist:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let origin = vec3(node.inputs[safe: 1]??.value)
            let axisIn = Point3D(x: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                                  y: node.inputs[safe: 3]??.value?.asDouble() ?? 0,
                                  z: node.inputs[safe: 4]??.value?.asDouble() ?? 1)
            let axis = axisIn.length > 1e-9 ? axisIn.normalized : Point3D(x: 0, y: 0, z: 1)
            let totalAngle = (node.inputs[safe: 5]??.value?.asDouble() ?? 90) * .pi / 180

            var projections: [Double] = []
            for shape in shapes {
                _ = shape.mapped { p in projections.append((p - origin).dot(axis)); return p }
            }
            guard let minP = projections.min(), let maxP = projections.max(), maxP - minP > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry(shapes)
                return
            }
            let span = maxP - minP
            node.outputs[safe: 0]??.value = .geometry(shapes.map { shape in
                shape.mapped { p in
                    let rel = p - origin
                    let alongAxis = axis.scaled(by: rel.dot(axis))
                    let radial = rel - alongAxis
                    let t = ((p - origin).dot(axis) - minP) / span
                    let rotatedRadial = radial.rotated(angle: totalAngle * t, axis: axis)
                    return origin + alongAxis + rotatedRadial
                }
            })

        case .geoTaper:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let origin = vec3(node.inputs[safe: 1]??.value)
            let axisIn = Point3D(x: node.inputs[safe: 2]??.value?.asDouble() ?? 0,
                                  y: node.inputs[safe: 3]??.value?.asDouble() ?? 0,
                                  z: node.inputs[safe: 4]??.value?.asDouble() ?? 1)
            let axis = axisIn.length > 1e-9 ? axisIn.normalized : Point3D(x: 0, y: 0, z: 1)
            let startFactor = node.inputs[safe: 5]??.value?.asDouble() ?? 1
            let endFactor = node.inputs[safe: 6]??.value?.asDouble() ?? 0.3

            var projections: [Double] = []
            for shape in shapes {
                _ = shape.mapped { p in projections.append((p - origin).dot(axis)); return p }
            }
            guard let minP = projections.min(), let maxP = projections.max(), maxP - minP > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry(shapes)
                return
            }
            let span = maxP - minP
            node.outputs[safe: 0]??.value = .geometry(shapes.map { shape in
                shape.mapped { p in
                    let rel = p - origin
                    let alongAxis = axis.scaled(by: rel.dot(axis))
                    let radial = rel - alongAxis
                    let t = ((p - origin).dot(axis) - minP) / span
                    let factor = startFactor + (endFactor - startFactor) * t
                    return origin + alongAxis + radial.scaled(by: factor)
                }
            })

        // MARK: Geometry primitives (additions)
        case .geoLineSDL:
            let start = vec3(node.inputs[safe: 0]??.value)
            let dirIn = vec3(node.inputs[safe: 1]??.value)
            let dir = dirIn.length > 1e-9 ? dirIn.normalized : Point3D(x: 1, y: 0, z: 0)
            let length = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .geometry([.line(start, start + dir.scaled(by: length))])

        case .geoCircleThreePt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let c = vec3(node.inputs[safe: 2]??.value)
            guard let circ = circumcircle(a, b, c) else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }
            let segs = 64
            let pts = (0...segs).map { i -> Point3D in
                let t = Double(i) / Double(segs) * 2 * .pi
                return circ.center + circ.u.scaled(by: circ.radius * cos(t)) + circ.v.scaled(by: circ.radius * sin(t))
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoArcThreePt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let c = vec3(node.inputs[safe: 2]??.value)
            guard let circ = circumcircle(a, b, c) else {
                node.outputs[safe: 0]??.value = .geometry([.line(a, c)])
                return
            }
            func angleOf(_ p: Point3D) -> Double {
                let rel = p - circ.center
                return atan2(rel.dot(circ.v), rel.dot(circ.u))
            }
            let angleA = angleOf(a)
            var angleB = angleOf(b) - angleA
            var angleC = angleOf(c) - angleA
            while angleB < 0 { angleB += 2 * .pi }
            while angleC < 0 { angleC += 2 * .pi }
            // Sweep from A to C in the direction that passes through B.
            let sweep = angleB <= angleC ? angleC : angleC - 2 * .pi
            let segs = max(4, Int(abs(sweep) / (2 * .pi) * 128) + 1)
            let pts = (0...segs).map { i -> Point3D in
                let t = angleA + sweep * Double(i) / Double(segs)
                return circ.center + circ.u.scaled(by: circ.radius * cos(t)) + circ.v.scaled(by: circ.radius * sin(t))
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])

        case .geoPolyline:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            let pts = shapes.compactMap { shape -> Point3D? in
                if case .point(let p) = shape { return p }
                if case .painted(.point(let p), _) = shape { return p }
                return nil
            }
            node.outputs[safe: 0]??.value = .geometry(pts.count >= 2 ? [.polyline(pts)] : [])

        // MARK: Curve (additions)
        case .curveExplode:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            guard pts.count >= 2 else { node.outputs[safe: 0]??.value = .geometry([]); return }
            let segments = (0..<(pts.count - 1)).map { GeometricShape.line(pts[$0], pts[$0 + 1]) }
            node.outputs[safe: 0]??.value = .geometry(segments)

        case .curveJoin:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value else { return }
            var curves: [[Point3D]] = shapes.compactMap { shape in
                guard let curve = CurveKernel.curveShape(from: shape) else { return nil }
                let pts = CurveKernel.polylinePoints(for: curve)
                return pts.count >= 2 ? pts : nil
            }
            var joined: [[Point3D]] = []
            let tol = 1e-4
            while !curves.isEmpty {
                var chain = curves.removeFirst()
                var extended = true
                while extended {
                    extended = false
                    for idx in curves.indices {
                        let candidate = curves[idx]
                        guard let chainStart = chain.first, let chainEnd = chain.last,
                              let candStart = candidate.first, let candEnd = candidate.last else { continue }
                        if (chainEnd - candStart).length < tol {
                            chain.append(contentsOf: candidate.dropFirst())
                        } else if (chainEnd - candEnd).length < tol {
                            chain.append(contentsOf: candidate.reversed().dropFirst())
                        } else if (chainStart - candEnd).length < tol {
                            chain.insert(contentsOf: candidate.dropLast(), at: 0)
                        } else if (chainStart - candStart).length < tol {
                            chain.insert(contentsOf: candidate.reversed().dropLast(), at: 0)
                        } else {
                            continue
                        }
                        curves.remove(at: idx)
                        extended = true
                        break
                    }
                }
                joined.append(chain)
            }
            node.outputs[safe: 0]??.value = .geometry(joined.map { .polyline($0) })

        case .curveFrame:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            let t = node.inputs[safe: 1]??.value?.asDouble() ?? 0.5
            let point = CurveKernel.pointAt(pts, t: t)
            let p1 = CurveKernel.pointAt(pts, t: max(0, t - 0.001))
            let p2 = CurveKernel.pointAt(pts, t: min(1, t + 0.001))
            let tangentRaw = p2 - p1
            let tangent = tangentRaw.length > 1e-9 ? tangentRaw.normalized : Point3D(x: 1, y: 0, z: 0)
            var xAxisRaw = tangent.cross(Point3D(x: 0, y: 0, z: 1))
            if xAxisRaw.length < 1e-6 { xAxisRaw = tangent.cross(Point3D(x: 1, y: 0, z: 0)) }
            let xAxis = xAxisRaw.length > 1e-9 ? xAxisRaw.normalized : Point3D(x: 1, y: 0, z: 0)
            node.outputs[safe: 0]??.value = .plane(origin: point, normal: tangent, xAxis: xAxis)

        case .curveArea:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            var pts = CurveKernel.polylinePoints(for: curve)
            if pts.count > 1, (pts.first! - pts.last!).length > 1e-9 { pts.append(pts.first!) }
            guard pts.count >= 4 else {
                node.outputs[safe: 0]??.value = .number(0)
                node.outputs[safe: 1]??.value = .vector3(x: 0, y: 0, z: 0)
                return
            }
            let loop = Array(pts.dropLast())
            let center = loop.reduce(Point3D.zero, +).scaled(by: 1.0 / Double(loop.count))
            var areaAcc = 0.0
            var centroidAcc = Point3D.zero
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                let triN = (a - center).cross(b - center)
                let triArea = triN.length / 2
                let triCentroid = (center + a + b).scaled(by: 1.0 / 3.0)
                areaAcc += triArea
                centroidAcc = centroidAcc + triCentroid.scaled(by: triArea)
            }
            let centroid = areaAcc > 1e-12 ? centroidAcc.scaled(by: 1.0 / areaAcc) : center
            node.outputs[safe: 0]??.value = .number(areaAcc)
            node.outputs[safe: 1]??.value = .vector3(x: centroid.x, y: centroid.y, z: centroid.z)

        // MARK: Surface (additions)
        case .surfaceFourPoint:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let c = vec3(node.inputs[safe: 2]??.value)
            let d = vec3(node.inputs[safe: 3]??.value)
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: [a, b, c, d], triangleIndices: [0, 1, 2, 0, 2, 3])])

        case .surfaceArea:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .number(totalMeshArea(md))

        case .meshClosestPoint:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let test = vec3(node.inputs[safe: 1]??.value)
            let result = closestPointOnMesh(md, to: test)
            node.outputs[safe: 0]??.value = .vector3(x: result.point.x, y: result.point.y, z: result.point.z)
            node.outputs[safe: 1]??.value = .number(result.distance)

        // MARK: Solid / Mesh (additions)
        case .deconstructMesh:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .number(Double(md.vertices.count))
            node.outputs[safe: 1]??.value = .number(Double(md.triangleIndices.count / 3))

        case .meshArea:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .number(totalMeshArea(md))

        case .joinMeshes:
            let a = combinedMeshData(node.inputs[safe: 0]??.value)
            let b = combinedMeshData(node.inputs[safe: 1]??.value)
            let merged: MeshKernel.MeshData
            if let a, let b { merged = MeshKernel.merge(a, b) }
            else if let a { merged = a }
            else if let b { merged = b }
            else { return }
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: merged.vertices, triangleIndices: merged.triangleIndices)])

        case .weldMesh:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            let tol = max(1e-9, node.inputs[safe: 1]??.value?.asDouble() ?? 0.001)
            var map: [String: Int] = [:]
            var newVerts: [Point3D] = []
            var remap: [Int] = []
            remap.reserveCapacity(md.vertices.count)
            for v in md.vertices {
                let key = "\(Int((v.x / tol).rounded())),\(Int((v.y / tol).rounded())),\(Int((v.z / tol).rounded()))"
                if let idx = map[key] {
                    remap.append(idx)
                } else {
                    let idx = newVerts.count
                    map[key] = idx
                    newVerts.append(v)
                    remap.append(idx)
                }
            }
            let newTris = md.triangleIndices.map { remap[$0] }
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: newVerts, triangleIndices: newTris)])

        case .deconstructBox:
            guard case .geometry(let shapes) = node.inputs[safe: 0]??.value,
                  let bbox = MeshKernel.boundingBox(of: shapes) else { return }
            node.outputs[safe: 0]??.value = .vector3(x: bbox.min.x, y: bbox.min.y, z: bbox.min.z)
            node.outputs[safe: 1]??.value = .vector3(x: bbox.max.x, y: bbox.max.y, z: bbox.max.z)
            let center = (bbox.min + bbox.max).scaled(by: 0.5)
            node.outputs[safe: 2]??.value = .vector3(x: center.x, y: center.y, z: center.z)

        // MARK: Geometry – more primitives (additions)
        case .geoBoxTwoPt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let mn = Point3D(x: min(a.x, b.x), y: min(a.y, b.y), z: min(a.z, b.z))
            let mx = Point3D(x: max(a.x, b.x), y: max(a.y, b.y), z: max(a.z, b.z))
            let md = MeshKernel.box(min: mn, max: mx)
            node.outputs[safe: 0]??.value = .geometry([
                .mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)
            ])

        case .geoBoxOriented:
            let pl = planeValue(node.inputs[safe: 0]??.value)
            let (xAxis, yAxis) = planeBasis(pl)
            let normal = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let sx = node.inputs[safe: 1]??.value?.asDouble() ?? 10
            let sy = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            let sz = node.inputs[safe: 3]??.value?.asDouble() ?? 10
            let half = Point3D(x: sx / 2, y: sy / 2, z: sz / 2)
            let local = MeshKernel.box(min: Point3D(x: -half.x, y: -half.y, z: -half.z), max: half)
            let verts = local.vertices.map { p in pl.origin + xAxis.scaled(by: p.x) + yAxis.scaled(by: p.y) + normal.scaled(by: p.z) }
            node.outputs[safe: 0]??.value = .geometry([
                .mesh(vertices: verts, triangleIndices: local.triangleIndices)
            ])

        case .geoCylinderTwoPt:
            let a = vec3(node.inputs[safe: 0]??.value)
            let b = vec3(node.inputs[safe: 1]??.value)
            let axis = b - a
            guard axis.length > 1e-9 else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }
            let radius = node.inputs[safe: 2]??.value?.asDouble() ?? 3
            let local = MeshKernel.cylinder(center: .zero, radius: radius, height: axis.length)
            let md = orientMeshAlongZ(local, to: axis, translate: (a + b).scaled(by: 0.5))
            node.outputs[safe: 0]??.value = .geometry([
                .mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)
            ])

        case .geoPyramid:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = max(0.001, node.inputs[safe: 1]??.value?.asDouble() ?? 5)
            let sides = max(3, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 4))
            let h = node.inputs[safe: 3]??.value?.asDouble() ?? 10
            let hh = h * 0.5
            let base = (0..<sides).map { i -> Point3D in
                let a = 2 * Double.pi * Double(i) / Double(sides)
                return c + Point3D(x: r * cos(a), y: r * sin(a), z: -hh)
            }
            let apex = c + Point3D(x: 0, y: 0, z: hh)
            var md = MeshKernel.extrudeToPoint(profile: base, apex: apex, capped: false)
            md = MeshKernel.merge(md, MeshKernel.fanCap(loop: base, flipped: true))
            node.outputs[safe: 0]??.value = .geometry([
                .mesh(vertices: md.vertices, triangleIndices: md.triangleIndices)
            ])

        // MARK: Plane (additions)
        case .planeBetweenLines:
            // Works for any curve shape (line, polyline, polygon, circle) —
            // not just straight `.line` segments — by sampling curve A and
            // walking to its closest approach against curve B.
            guard let curveA = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value),
                  let curveB = CurveKernel.firstCurve(from: node.inputs[safe: 1]??.value) else { return }
            let ptsA = CurveKernel.polylinePoints(for: curveA)
            let ptsB = CurveKernel.polylinePoints(for: curveB)
            guard ptsA.count >= 2, ptsB.count >= 2 else { return }

            let cumA = CurveKernel.cumulativeLengths(for: ptsA)
            let totalA = cumA.last ?? 0
            let cumB = CurveKernel.cumulativeLengths(for: ptsB)
            let totalB = cumB.last ?? 0

            let sampleCount = max(16, min(200, ptsA.count + ptsB.count))
            var bestDist = Double.infinity
            var bestTA = 0.0
            for i in 0...sampleCount {
                let t = Double(i) / Double(sampleCount)
                let pa = CurveKernel.point(atLength: t * totalA, along: ptsA, cumulativeLengths: cumA)
                let hit = CurveKernel.closestPoint(ptsB, to: pa)
                if hit.distance < bestDist { bestDist = hit.distance; bestTA = t }
            }
            let meetA = CurveKernel.point(atLength: bestTA * totalA, along: ptsA, cumulativeLengths: cumA)
            let hitB = CurveKernel.closestPoint(ptsB, to: meetA)
            let meet = (meetA + hitB.point).scaled(by: 0.5)

            // Tangent at the closest-approach parameter, oriented so it points
            // "into" the meeting point from whichever end of the curve is farther —
            // this is what makes the bisector below a true miter plane when the
            // two curves meet at (or near) their endpoints.
            func orientedTangent(_ points: [Point3D], _ cumulative: [Double], _ total: Double, _ t: Double) -> Point3D {
                let eps = 0.001
                let p1 = CurveKernel.point(atLength: max(0, t - eps) * total, along: points, cumulativeLengths: cumulative)
                let p2 = CurveKernel.point(atLength: min(1, t + eps) * total, along: points, cumulativeLengths: cumulative)
                let forward = p2 - p1
                guard forward.length > 1e-9 else { return Point3D(x: 1, y: 0, z: 0) }
                return forward.normalized.scaled(by: t >= 0.5 ? 1 : -1)
            }

            let dirA = orientedTangent(ptsA, cumA, totalA, bestTA)
            let dirB = orientedTangent(ptsB, cumB, totalB, hitB.t)

            var normal = dirA + dirB
            if normal.length < 1e-9 { normal = dirA.cross(Point3D(x: 0, y: 0, z: 1)) }
            let normalN = normal.length > 1e-9 ? normal.normalized : Point3D(x: 0, y: 0, z: 1)
            var xAxisRaw = normalN.cross(Point3D(x: 0, y: 0, z: 1))
            if xAxisRaw.length < 1e-6 { xAxisRaw = normalN.cross(Point3D(x: 1, y: 0, z: 0)) }
            let xAxis = xAxisRaw.length > 1e-9 ? xAxisRaw.normalized : Point3D(x: 1, y: 0, z: 0)
            node.outputs[safe: 0]??.value = .plane(origin: meet, normal: normalN, xAxis: xAxis)

        // MARK: Math – trig / rounding / constants (additions)
        case .sine:
            node.outputs[safe: 0]??.value = .number(sin((node.inputs[safe: 0]??.value?.asDouble() ?? 0) * .pi / 180))
        case .cosine:
            node.outputs[safe: 0]??.value = .number(cos((node.inputs[safe: 0]??.value?.asDouble() ?? 0) * .pi / 180))
        case .tangent:
            node.outputs[safe: 0]??.value = .number(tan((node.inputs[safe: 0]??.value?.asDouble() ?? 0) * .pi / 180))
        case .arcsine:
            let a = max(-1, min(1, node.inputs[safe: 0]??.value?.asDouble() ?? 0))
            node.outputs[safe: 0]??.value = .number(asin(a) * 180 / .pi)
        case .arccosine:
            let a = max(-1, min(1, node.inputs[safe: 0]??.value?.asDouble() ?? 0))
            node.outputs[safe: 0]??.value = .number(acos(a) * 180 / .pi)
        case .arctangent2:
            let y = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let x = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            node.outputs[safe: 0]??.value = .number(atan2(y, x) * 180 / .pi)
        case .squareRoot:
            node.outputs[safe: 0]??.value = .number(sqrt(max(0, node.inputs[safe: 0]??.value?.asDouble() ?? 0)))
        case .mathRound:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0).rounded())
        case .mathFloor:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0).rounded(.down))
        case .mathCeiling:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0).rounded(.up))
        case .mathTruncate:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0).rounded(.towardZero))
        case .mathMin:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(min(a, b))
        case .mathMax:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(max(a, b))
        case .degreesToRadians:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0) * .pi / 180)
        case .radiansToDegrees:
            node.outputs[safe: 0]??.value = .number((node.inputs[safe: 0]??.value?.asDouble() ?? 0) * 180 / .pi)
        case .constantPi:
            node.outputs[safe: 0]??.value = .number(.pi)
        case .mathLog:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 1
            let base = node.inputs[safe: 1]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .number(a > 0 && base > 0 && abs(base - 1) > 1e-9 ? log(a) / log(base) : 0)
        case .mathExp:
            node.outputs[safe: 0]??.value = .number(exp(node.inputs[safe: 0]??.value?.asDouble() ?? 1))
        case .mathExpression:
            var vars = [String: Double]()
            for port in node.inputs { vars[port.name] = port.value?.asDouble() ?? 0 }
            node.outputs[safe: 0]??.value = .number(MathExpression.evaluate(node.expression, variables: vars) ?? 0)

        // MARK: Logic (additions)
        case .logicXor:
            let a = (node.inputs[safe: 0]??.value?.asDouble() ?? 0) != 0
            let b = (node.inputs[safe: 1]??.value?.asDouble() ?? 0) != 0
            node.outputs[safe: 0]??.value = .boolean(a != b)

        // MARK: Vector (additions)
        case .vectorSetLength:
            let v = vec3(node.inputs[safe: 0]??.value)
            let length = node.inputs[safe: 1]??.value?.asDouble() ?? 1
            let result = v.length > 1e-9 ? v.normalized.scaled(by: length) : v
            node.outputs[safe: 0]??.value = .vector3(x: result.x, y: result.y, z: result.z)
        case .unitX:
            node.outputs[safe: 0]??.value = .vector3(x: 1, y: 0, z: 0)
        case .unitY:
            node.outputs[safe: 0]??.value = .vector3(x: 0, y: 1, z: 0)
        case .unitZ:
            node.outputs[safe: 0]??.value = .vector3(x: 0, y: 0, z: 1)

        // MARK: Params – Color (additions)
        case .constructColor:
            let r = max(0, min(1, node.inputs[safe: 0]??.value?.asDouble() ?? 0.7))
            let g = max(0, min(1, node.inputs[safe: 1]??.value?.asDouble() ?? 0.7))
            let b = max(0, min(1, node.inputs[safe: 2]??.value?.asDouble() ?? 0.7))
            let a = max(0, min(1, node.inputs[safe: 3]??.value?.asDouble() ?? 1))
            node.outputs[safe: 0]??.value = .color(Color(red: r, green: g, blue: b, opacity: a))

        case .deconstructColor:
            guard let c = node.inputs[safe: 0]??.value?.asColorComponentsRGBA() else { return }
            node.outputs[safe: 0]??.value = .number(c.r)
            node.outputs[safe: 1]??.value = .number(c.g)
            node.outputs[safe: 2]??.value = .number(c.b)
            node.outputs[safe: 3]??.value = .number(c.a)

        case .constructColorRGB:
            let r = max(0, min(1, node.inputs[safe: 0]??.value?.asDouble() ?? 0.7))
            let g = max(0, min(1, node.inputs[safe: 1]??.value?.asDouble() ?? 0.7))
            let b = max(0, min(1, node.inputs[safe: 2]??.value?.asDouble() ?? 0.7))
            node.outputs[safe: 0]??.value = .color(Color(red: r, green: g, blue: b))

        // MARK: Curve (additions)
        case .curveDivideLength:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            let cum = CurveKernel.cumulativeLengths(for: pts)
            let total = cum.last ?? 0
            let step = max(1e-6, node.inputs[safe: 1]??.value?.asDouble() ?? 1)
            guard total > 1e-9 else { node.outputs[safe: 0]??.value = .geometry([]); return }
            var result: [GeometricShape] = []
            var d = 0.0
            while d <= total + 1e-9 {
                result.append(.point(CurveKernel.point(atLength: d, along: pts, cumulativeLengths: cum)))
                d += step
            }
            node.outputs[safe: 0]??.value = .geometry(result)

        case .evaluateCurve:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            let t = node.inputs[safe: 1]??.value?.asDouble() ?? 0.5
            let point = CurveKernel.pointAt(pts, t: t)
            let p1 = CurveKernel.pointAt(pts, t: max(0, t - 0.001))
            let p2 = CurveKernel.pointAt(pts, t: min(1, t + 0.001))
            let tangentRaw = p2 - p1
            let tangent = tangentRaw.length > 1e-9 ? tangentRaw.normalized : Point3D(x: 1, y: 0, z: 0)
            node.outputs[safe: 0]??.value = .vector3(x: point.x, y: point.y, z: point.z)
            node.outputs[safe: 1]??.value = .vector3(x: tangent.x, y: tangent.y, z: tangent.z)

        case .curveCurvature:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            let t = node.inputs[safe: 1]??.value?.asDouble() ?? 0.5
            let eps = 0.01
            let p0 = CurveKernel.pointAt(pts, t: max(0, t - eps))
            let p1 = CurveKernel.pointAt(pts, t: t)
            let p2 = CurveKernel.pointAt(pts, t: min(1, t + eps))
            guard let circ = circumcircle(p0, p1, p2) else {
                node.outputs[safe: 0]??.value = .number(.infinity)
                node.outputs[safe: 1]??.value = .vector3(x: p1.x, y: p1.y, z: p1.z)
                return
            }
            node.outputs[safe: 0]??.value = .number(circ.radius)
            node.outputs[safe: 1]??.value = .vector3(x: circ.center.x, y: circ.center.y, z: circ.center.z)

        case .isCurveClosed:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let pts = CurveKernel.polylinePoints(for: curve)
            let closed = pts.count > 1 && (pts.first! - pts.last!).length < 1e-6
            node.outputs[safe: 0]??.value = .boolean(closed)

        // MARK: Solid / Mesh (additions)
        case .isMeshClosed:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            node.outputs[safe: 0]??.value = .boolean(meshIsClosed(md))

        case .flipMesh:
            guard let md = combinedMeshData(node.inputs[safe: 0]??.value) else { return }
            var tris = md.triangleIndices
            var idx = 0
            while idx + 2 < tris.count {
                tris.swapAt(idx + 1, idx + 2)
                idx += 3
            }
            node.outputs[safe: 0]??.value = .geometry([.mesh(vertices: md.vertices, triangleIndices: tris)])

        // MARK: Intersect (additions)
        case .lineSphereIntersect:
            guard let (p0, p1) = firstLineEndpoints(node.inputs[safe: 0]??.value) else { return }
            let center = vec3(node.inputs[safe: 1]??.value)
            let radius = node.inputs[safe: 2]??.value?.asDouble() ?? 5
            let d = p1 - p0
            let f = p0 - center
            let a = d.dot(d)
            let b = 2 * f.dot(d)
            let c = f.dot(f) - radius * radius
            let disc = b * b - 4 * a * c
            guard a > 1e-12, disc >= 0 else {
                node.outputs[safe: 2]??.value = .boolean(false)
                return
            }
            let sq = sqrt(disc)
            let t1 = (-b - sq) / (2 * a)
            let t2 = (-b + sq) / (2 * a)
            let ptA = p0 + d.scaled(by: t1)
            let ptB = p0 + d.scaled(by: t2)
            node.outputs[safe: 0]??.value = .vector3(x: ptA.x, y: ptA.y, z: ptA.z)
            node.outputs[safe: 1]??.value = .vector3(x: ptB.x, y: ptB.y, z: ptB.z)
            node.outputs[safe: 2]??.value = .boolean(true)

        case .spherePlaneIntersect:
            let center = vec3(node.inputs[safe: 0]??.value)
            let radius = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let pl = planeValue(node.inputs[safe: 2]??.value)
            let n = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
            let d = (center - pl.origin).dot(n)
            guard abs(d) <= radius else {
                node.outputs[safe: 0]??.value = .geometry([])
                node.outputs[safe: 1]??.value = .boolean(false)
                return
            }
            let circleRadius = sqrt(max(0, radius * radius - d * d))
            let circleCenter = center - n.scaled(by: d)
            let (xAxis, yAxis) = planeBasis((origin: circleCenter, normal: n, xAxis: pl.xAxis))
            let segs = 64
            let pts = (0...segs).map { i -> Point3D in
                let t = Double(i) / Double(segs) * 2 * .pi
                return circleCenter + xAxis.scaled(by: circleRadius * cos(t)) + yAxis.scaled(by: circleRadius * sin(t))
            }
            node.outputs[safe: 0]??.value = .geometry([.polyline(pts)])
            node.outputs[safe: 1]??.value = .boolean(true)

        case .pointInBox:
            guard case .geometry(let shapes) = node.inputs[safe: 1]??.value,
                  let bbox = MeshKernel.boundingBox(of: shapes) else { return }
            let p = vec3(node.inputs[safe: 0]??.value)
            let inside = p.x >= bbox.min.x && p.x <= bbox.max.x
                && p.y >= bbox.min.y && p.y <= bbox.max.y
                && p.z >= bbox.min.z && p.z <= bbox.max.z
            node.outputs[safe: 0]??.value = .boolean(inside)

        // MARK: Curve – Spline
        case .curveNurbsCurve:
            let pts = pointList(from: node.inputs[safe: 0]??.value)
            guard pts.count >= 2 else { node.outputs[safe: 0]??.value = .geometry([]); return }
            let degree = max(1, Int(node.inputs[safe: 1]??.value?.asDouble() ?? 3))
            let closed = (node.inputs[safe: 2]??.value?.asDouble() ?? 0) != 0
            node.outputs[safe: 0]??.value = .geometry([.spline(controlPoints: pts, degree: degree, closed: closed)])

        case .curveControlPoints:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let cps = CurveKernel.controlPoints(for: curve)
            node.outputs[safe: 0]??.value = .geometry(cps.map { .point($0) })
            node.outputs[safe: 1]??.value = .number(Double(cps.count))

        case .curveRebuild:
            guard let curve = CurveKernel.firstCurve(from: node.inputs[safe: 0]??.value) else { return }
            let count = max(2, Int(node.inputs[safe: 1]??.value?.asDouble() ?? 10))
            let degree = max(1, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 3))
            let pts = CurveKernel.resample(shape: curve, sampleCount: count)
            let (cps, actualDegree) = CurveKernel.interpolatedSpline(through: pts, degree: degree)
            node.outputs[safe: 0]??.value = .geometry([.spline(controlPoints: cps, degree: actualDegree, closed: false)])
        }
    }

    /// Extracts an ordered point list from a `.geometry` port carrying
    /// `.point` shapes (used by the point-cloud inputs of the Spline nodes).
    private static func pointList(from value: PortValue?) -> [Point3D] {
        guard case .geometry(let shapes) = value else { return [] }
        return shapes.compactMap { shape -> Point3D? in
            if case .point(let p) = shape { return p }
            if case .painted(.point(let p), _) = shape { return p }
            return nil
        }
    }

    private static func planeValue(_ value: PortValue?) -> (origin: Point3D, normal: Point3D, xAxis: Point3D) {
        if case .plane(let origin, let normal, let xAxis) = value { return (origin, normal, xAxis) }
        return (.zero, Point3D(x: 0, y: 0, z: 1), Point3D(x: 1, y: 0, z: 0))
    }

    private static func geometryShapes(_ value: PortValue?) -> [GeometricShape] {
        if case .geometry(let shapes) = value { return shapes }
        return []
    }

    /// Tessellates and merges every mesh-representable shape in a geometry
    /// port's list into one mesh (used by solid ops that treat the whole
    /// input as a single volume).
    private static func combinedMeshData(_ value: PortValue?) -> MeshKernel.MeshData? {
        var result: MeshKernel.MeshData?
        for shape in geometryShapes(value) {
            guard let md = MeshKernel.meshData(from: shape) else { continue }
            result = result.map { MeshKernel.merge($0, md) } ?? md
        }
        return result
    }

    /// The first mesh-representable shape in a geometry port's list (used by
    /// binary ops like Boolean that expect a single solid per input).
    private static func firstMeshData(_ value: PortValue?) -> MeshKernel.MeshData? {
        for shape in geometryShapes(value) {
            if let md = MeshKernel.meshData(from: shape) { return md }
        }
        return nil
    }

    private static func firstLineEndpoints(_ value: PortValue?) -> (Point3D, Point3D)? {
        for shape in geometryShapes(value) {
            switch shape {
            case .line(let a, let b): return (a, b)
            case .painted(.line(let a, let b), _): return (a, b)
            case .styled2D(.line(let a, let b), _): return (a, b)
            default: continue
            }
        }
        if let curve = CurveKernel.firstCurve(from: value) {
            let pts = CurveKernel.polylinePoints(for: curve)
            if pts.count >= 2 { return (pts[0], pts[1]) }
        }
        return nil
    }

    /// Best-effort mesh/plane cross-section: reports each triangle's
    /// intersection with the plane as an independent segment (not stitched
    /// into closed loops).
    private static func meshPlaneCrossSections(_ mesh: MeshKernel.MeshData, planeOrigin: Point3D, planeNormal: Point3D) -> [(Point3D, Point3D)] {
        var segments: [(Point3D, Point3D)] = []
        let tris = mesh.triangleIndices
        func side(_ p: Point3D) -> Double { (p - planeOrigin).dot(planeNormal) }
        var t = 0
        while t + 2 < tris.count {
            let a = mesh.vertices[tris[t]], b = mesh.vertices[tris[t + 1]], c = mesh.vertices[tris[t + 2]]
            let sa = side(a), sb = side(b), sc = side(c)
            var pts: [Point3D] = []
            func edge(_ p1: Point3D, _ s1: Double, _ p2: Point3D, _ s2: Double) {
                if (s1 > 0) != (s2 > 0), abs(s1 - s2) > 1e-12 {
                    let frac = s1 / (s1 - s2)
                    pts.append(p1 + (p2 - p1).scaled(by: frac))
                }
            }
            edge(a, sa, b, sb)
            edge(b, sb, c, sc)
            edge(c, sc, a, sa)
            if pts.count == 2 { segments.append((pts[0], pts[1])) }
            t += 3
        }
        return segments
    }

    /// Extracts the tangent direction of a line at a given point.
    /// Finds the line in the geometry port, identifies which endpoint is closest to `pt`,
    /// and returns the unit vector from the far endpoint toward `pt`.
    private static func lineTangent(at pt: Point3D, from portValue: PortValue?) -> Point3D? {
        guard case .geometry(let shapes) = portValue else { return nil }
        for shape in shapes {
            let line: (Point3D, Point3D)?
            switch shape {
            case .line(let a, let b):                  line = (a, b)
            case .painted(.line(let a, let b), _):     line = (a, b)
            case .styled2D(.line(let a, let b), _):    line = (a, b)
            default:                                    line = nil
            }
            guard let (a, b) = line else { continue }

            let dA = pow(a.x - pt.x, 2) + pow(a.y - pt.y, 2) + pow(a.z - pt.z, 2)
            let dB = pow(b.x - pt.x, 2) + pow(b.y - pt.y, 2) + pow(b.z - pt.z, 2)

            // Pick the near and far endpoints
            let far: Point3D
            if dA < dB {
                far = b   // A is closest to pt, line direction = from B → A
            } else {
                far = a   // B is closest to pt, line direction = from A → B
            }

            let dx = pt.x - far.x
            let dy = pt.y - far.y
            let dz = pt.z - far.z
            let len = sqrt(dx * dx + dy * dy + dz * dz)
            guard len > 1e-12 else { continue }
            return Point3D(x: dx / len, y: dy / len, z: dz / len)
        }
        return nil
    }

    /// Rotates a mesh built around the local +Z axis (e.g. `MeshKernel.cylinder`)
    /// so its axis aligns with `axis`, then translates it to `translate`. Used
    /// by point-to-point primitives (`.geoCylinderTwoPt`) that need an
    /// arbitrarily-oriented instance of an axis-aligned mesh builder.
    private static func orientMeshAlongZ(_ md: MeshKernel.MeshData, to axis: Point3D, translate: Point3D) -> MeshKernel.MeshData {
        let target = axis.length > 1e-9 ? axis.normalized : Point3D(x: 0, y: 0, z: 1)
        let worldZ = Point3D(x: 0, y: 0, z: 1)
        let rotAxis = worldZ.cross(target)
        let dot = max(-1, min(1, worldZ.dot(target)))
        let transform: (Point3D) -> Point3D
        if rotAxis.length < 1e-9 {
            if dot > 0 {
                transform = { $0 }
            } else {
                transform = { $0.rotated(angle: .pi, axis: Point3D(x: 1, y: 0, z: 0)) }
            }
        } else {
            let angle = acos(dot)
            let rAxis = rotAxis.normalized
            transform = { $0.rotated(angle: angle, axis: rAxis) }
        }
        let verts = md.vertices.map { transform($0) + translate }
        return (verts, md.triangleIndices)
    }

    private static func vec3(_ v: PortValue?) -> Point3D {
        if case .vector3(let x, let y, let z) = v { return Point3D(x: x, y: y, z: z) }
        return .zero
    }

    /// In-plane X/Y basis vectors for a plane value, orthonormalized against its normal.
    private static func planeBasis(_ pl: (origin: Point3D, normal: Point3D, xAxis: Point3D)) -> (x: Point3D, y: Point3D) {
        let normal = pl.normal.length > 1e-9 ? pl.normal.normalized : Point3D(x: 0, y: 0, z: 1)
        let xAxis = pl.xAxis.length > 1e-9 ? pl.xAxis.normalized : Point3D(x: 1, y: 0, z: 0)
        let yAxis = normal.cross(xAxis).normalized
        return (xAxis, yAxis)
    }

    /// Circumcircle of three points in 3D: returns its center, radius, and an
    /// orthonormal in-plane basis (u, v) so points can be re-evaluated as
    /// `center + u*r*cos(t) + v*r*sin(t)`. `nil` when the points are collinear.
    private static func circumcircle(_ a: Point3D, _ b: Point3D, _ c: Point3D) -> (center: Point3D, radius: Double, u: Point3D, v: Point3D)? {
        let ab = b - a, ac = c - a
        let normal = ab.cross(ac)
        guard normal.length > 1e-9 else { return nil }
        let denom = 2 * normal.dot(normal)
        let toCenter = (normal.cross(ab).scaled(by: ac.dot(ac)) + ac.cross(normal).scaled(by: ab.dot(ab))).scaled(by: 1 / denom)
        let center = a + toCenter
        let radius = toCenter.length
        guard radius > 1e-9 else { return nil }
        let u = (a - center).normalized
        let v = normal.normalized.cross(u).normalized
        return (center, radius, u, v)
    }

    private static func triangleArea(_ a: Point3D, _ b: Point3D, _ c: Point3D) -> Double {
        (b - a).cross(c - a).length / 2
    }

    private static func totalMeshArea(_ md: MeshKernel.MeshData) -> Double {
        var area = 0.0
        let tris = md.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            area += triangleArea(md.vertices[tris[t]], md.vertices[tris[t + 1]], md.vertices[tris[t + 2]])
            t += 3
        }
        return area
    }

    /// A mesh is closed (watertight) when every edge is shared by exactly two
    /// triangles — i.e. it has no naked (boundary) edges.
    private static func meshIsClosed(_ md: MeshKernel.MeshData) -> Bool {
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) * 1_000_000 + Int64(max(a, b)) }
        var edgeCount: [Int64: Int] = [:]
        let tris = md.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let a = tris[t], b = tris[t + 1], c = tris[t + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] { edgeCount[key(u, v), default: 0] += 1 }
            t += 3
        }
        return !edgeCount.values.contains(1)
    }

    /// Closest point to `test` on any triangle of the mesh (brute-force scan).
    private static func closestPointOnMesh(_ md: MeshKernel.MeshData, to test: Point3D) -> (point: Point3D, distance: Double) {
        var best = md.vertices.first ?? .zero
        var bestDist = Double.infinity
        let tris = md.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let candidate = closestPointOnTriangle(test, md.vertices[tris[t]], md.vertices[tris[t + 1]], md.vertices[tris[t + 2]])
            let d = (test - candidate).length
            if d < bestDist { bestDist = d; best = candidate }
            t += 3
        }
        return (best, bestDist)
    }

    /// Closest point on triangle (a,b,c) to point `p`. Standard barycentric-region algorithm.
    private static func closestPointOnTriangle(_ p: Point3D, _ a: Point3D, _ b: Point3D, _ c: Point3D) -> Point3D {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = ab.dot(ap), d2 = ac.dot(ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = p - b
        let d3 = ab.dot(bp), d4 = ac.dot(bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return a + ab.scaled(by: v)
        }

        let cp = p - c
        let d5 = ab.dot(cp), d6 = ac.dot(cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return a + ac.scaled(by: w)
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + (c - b).scaled(by: w)
        }

        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return a + ab.scaled(by: v) + ac.scaled(by: w)
    }

    private static func textValue(_ v: PortValue?) -> String {
        switch v {
        case .text(let s): return s
        case .number(let n): return String(format: "%.3g", n)
        case .boolean(let b): return b ? "true" : "false"
        default: return ""
        }
    }
}

/// Deterministic PRNG (splitmix64) so `.populate3D` produces stable point
/// clouds for a given seed across re-evaluations.
struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// Safe subscript for arrays returning optional-optional (for in-place mutation)
extension Array {
    subscript(safe index: Int) -> Element?? {
        get {
            guard indices.contains(index) else { return .some(nil) }
            return .some(self[index])
        }
        set {
            guard indices.contains(index), let newValue, let val = newValue else { return }
            self[index] = val
        }
    }
}
