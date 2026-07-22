import Foundation
import SwiftUI

enum NodeEvaluator {
    static func evaluate(node: Node) {
        switch node.kind {
        // Params — values are set by UI, just pass through
        case .numberSlider, .numberInput, .booleanToggle, .textInput, .colorPicker, .point2D, .point3D:
            break

        // Math binary
        case .add:
            let a = node.inputs[safe: 0]??.value?.asDouble() ?? 0
            let b = node.inputs[safe: 1]??.value?.asDouble() ?? 0
            node.outputs[safe: 0]??.value = .number(a + b)

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
            node.outputs[safe: 0]??.value = .geometry([
                painted(.circle(center: c, radius: r), node.inputs[safe: 2]??.value)
            ])

        case .geoPolygon:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = max(0.001, node.inputs[safe: 1]??.value?.asDouble() ?? 5)
            let sides = max(3, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 6))
            let pts = (0..<sides).map { i -> Point3D in
                let a = Double(i) / Double(sides) * 2 * .pi
                return Point3D(x: c.x + r * cos(a), y: c.y + r * sin(a), z: c.z)
            }
            node.outputs[safe: 0]??.value = .geometry([
                painted(.polygon(pts), node.inputs[safe: 3]??.value)
            ])

        case .geoRectangle:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let hw = (node.inputs[safe: 1]??.value?.asDouble() ?? 10) / 2
            let hh = (node.inputs[safe: 2]??.value?.asDouble() ?? 5)  / 2
            let pts = [Point3D(x: c.x-hw, y: c.y-hh, z: c.z),
                       Point3D(x: c.x+hw, y: c.y-hh, z: c.z),
                       Point3D(x: c.x+hw, y: c.y+hh, z: c.z),
                       Point3D(x: c.x-hw, y: c.y+hh, z: c.z)]
            node.outputs[safe: 0]??.value = .geometry([
                painted(.polygon(pts), node.inputs[safe: 3]??.value)
            ])

        case .geoEllipse:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let rx = node.inputs[safe: 1]??.value?.asDouble() ?? 8
            let ry = node.inputs[safe: 2]??.value?.asDouble() ?? 4
            let segs = 64
            let pts = (0...segs).map { i -> Point3D in
                let a = Double(i) / Double(segs) * 2 * .pi
                return Point3D(x: c.x + rx * cos(a), y: c.y + ry * sin(a), z: c.z)
            }
            node.outputs[safe: 0]??.value = .geometry([
                painted(.polyline(pts), node.inputs[safe: 3]??.value)
            ])

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

        case .geoLoftSurface:
            guard
                let curveA = firstCurve(from: node.inputs[safe: 0]??.value),
                let curveB = firstCurve(from: node.inputs[safe: 1]??.value)
            else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }

            let sampleCount = max(2, Int(node.inputs[safe: 2]??.value?.asDouble() ?? 24))
            let sampledA = resampleCurve(curveA, sampleCount: sampleCount)
            let sampledB = resampleCurve(curveB, sampleCount: sampleCount)

            guard sampledA.count == sampledB.count, sampledA.count >= 2 else {
                node.outputs[safe: 0]??.value = .geometry([])
                return
            }

            node.outputs[safe: 0]??.value = .geometry([
                painted(.surfaceStrip(sampledA, sampledB), node.inputs[safe: 3]??.value)
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
            node.outputs[safe: 0]??.value = .geometry([
                painted(.sphere(center: c, radius: r), node.inputs[safe: 2]??.value)
            ])

        case .geoBox:
            let c  = vec3(node.inputs[safe: 0]??.value)
            let hw = (node.inputs[safe: 1]??.value?.asDouble() ?? 10) / 2
            let hh = (node.inputs[safe: 2]??.value?.asDouble() ?? 10) / 2
            let hd = (node.inputs[safe: 3]??.value?.asDouble() ?? 10) / 2
            node.outputs[safe: 0]??.value = .geometry([
                painted(.box(Point3D(x: c.x-hw, y: c.y-hh, z: c.z-hd),
                             Point3D(x: c.x+hw, y: c.y+hh, z: c.z+hd)),
                        node.inputs[safe: 4]??.value)
            ])

        case .geoCylinder:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let h = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .geometry([
                painted(.cylinder(center: c, radius: r, height: h), node.inputs[safe: 3]??.value)
            ])

        case .geoCone:
            let c = vec3(node.inputs[safe: 0]??.value)
            let r = node.inputs[safe: 1]??.value?.asDouble() ?? 5
            let h = node.inputs[safe: 2]??.value?.asDouble() ?? 10
            node.outputs[safe: 0]??.value = .geometry([
                painted(.cone(center: c, radius: r, height: h), node.inputs[safe: 3]??.value)
            ])

        case .geoTorus:
            let c    = vec3(node.inputs[safe: 0]??.value)
            let majR = node.inputs[safe: 1]??.value?.asDouble() ?? 8
            let minR = node.inputs[safe: 2]??.value?.asDouble() ?? 2
            node.outputs[safe: 0]??.value = .geometry([
                painted(.torus(center: c, majorRadius: majR, minorRadius: minR), node.inputs[safe: 3]??.value)
            ])

        case .material:
            let r     = max(0, min(1, node.inputs[safe: 0]??.value?.asDouble() ?? 0.72))
            let g     = max(0, min(1, node.inputs[safe: 1]??.value?.asDouble() ?? 0.72))
            let b     = max(0, min(1, node.inputs[safe: 2]??.value?.asDouble() ?? 0.78))
            let rough = max(0, min(1, node.inputs[safe: 3]??.value?.asDouble() ?? 0.35))
            let metal = max(0, min(1, node.inputs[safe: 4]??.value?.asDouble() ?? 0.0))
            let specular = max(0, min(1, node.inputs[safe: 5]??.value?.asDouble() ?? 0.55))
            let clearcoat = max(0, min(1, node.inputs[safe: 6]??.value?.asDouble() ?? 0.10))
            let normal = max(0, min(1, node.inputs[safe: 7]??.value?.asDouble() ?? 0.22))
            let textureScale = max(0.1, min(24, node.inputs[safe: 8]??.value?.asDouble() ?? 1.0))
            let roughnessVariation = max(0, min(1, node.inputs[safe: 9]??.value?.asDouble() ?? 0.16))
            let anisotropy = max(0, min(1, node.inputs[safe: 10]??.value?.asDouble() ?? 0.0))
            let surfaceType = textValue(node.inputs[safe: 11]??.value)
            let finish = textValue(node.inputs[safe: 12]??.value)
            let pattern = textValue(node.inputs[safe: 13]??.value)
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
                    roughnessPattern: pattern
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
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.58, g: 0.60, b: 0.64,
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
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.72, g: 0.74, b: 0.76,
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
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.60, g: 0.62, b: 0.64,
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
            node.outputs[safe: 0]??.value = .material(
                Material3D(
                    r: 0.78, g: 0.79, b: 0.82,
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
        }
    }

    /// Wraps `shape` in `.painted` only when a material value is present on the port.
    private static func painted(_ shape: GeometricShape, _ portValue: PortValue?) -> GeometricShape {
        if case .material(let mat) = portValue { return .painted(shape, mat) }
        return shape
    }

    private static func vec3(_ v: PortValue?) -> Point3D {
        if case .vector3(let x, let y, let z) = v { return Point3D(x: x, y: y, z: z) }
        return .zero
    }

    private static func firstCurve(from value: PortValue?) -> GeometricShape? {
        guard case .geometry(let shapes) = value else { return nil }
        for shape in shapes {
            if let curve = curveShape(from: shape) {
                return curve
            }
        }
        return nil
    }

    private static func curveShape(from shape: GeometricShape) -> GeometricShape? {
        switch shape {
        case .line, .polyline, .polygon, .circle:
            return shape
        case .painted(let inner, _):
            return curveShape(from: inner)
        default:
            return nil
        }
    }

    private static func resampleCurve(_ shape: GeometricShape, sampleCount: Int) -> [Point3D] {
        let polyline = polylinePoints(for: shape)
        guard polyline.count >= 2 else { return [] }
        if polyline.count == sampleCount { return polyline }

        let lengths = cumulativeLengths(for: polyline)
        let total = lengths.last ?? 0
        guard total > 1e-9 else { return Array(repeating: polyline[0], count: sampleCount) }

        return (0..<sampleCount).map { index in
            let t = Double(index) / Double(sampleCount - 1)
            return point(atLength: t * total, along: polyline, cumulativeLengths: lengths)
        }
    }

    private static func polylinePoints(for shape: GeometricShape) -> [Point3D] {
        switch shape {
        case .line(let a, let b):
            return [a, b]
        case .polyline(let points):
            return points
        case .polygon(let points):
            guard let first = points.first else { return [] }
            return points + [first]
        case .circle(let center, let radius):
            let segments = 64
            return (0...segments).map { index in
                let angle = Double(index) / Double(segments) * 2 * .pi
                return Point3D(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle),
                    z: center.z
                )
            }
        case .painted(let inner, _):
            return polylinePoints(for: inner)
        default:
            return []
        }
    }

    private static func cumulativeLengths(for points: [Point3D]) -> [Double] {
        var lengths: [Double] = [0]
        for index in 1..<points.count {
            let segment = points[index] - points[index - 1]
            let length = sqrt(segment.x * segment.x + segment.y * segment.y + segment.z * segment.z)
            lengths.append(lengths[index - 1] + length)
        }
        return lengths
    }

    private static func point(atLength target: Double, along points: [Point3D], cumulativeLengths: [Double]) -> Point3D {
        for index in 1..<points.count {
            let startLength = cumulativeLengths[index - 1]
            let endLength = cumulativeLengths[index]
            if target <= endLength || index == points.count - 1 {
                let span = endLength - startLength
                guard span > 1e-9 else { return points[index] }
                let localT = (target - startLength) / span
                let a = points[index - 1]
                let b = points[index]
                return Point3D(
                    x: a.x + (b.x - a.x) * localT,
                    y: a.y + (b.y - a.y) * localT,
                    z: a.z + (b.z - a.z) * localT
                )
            }
        }
        return points.last ?? .zero
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
