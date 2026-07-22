import Foundation

// MARK: - Material3D

enum MaterialSurfaceType: String, CaseIterable, Hashable {
    case plastic
    case metal

    static func parse(_ rawValue: String) -> MaterialSurfaceType {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Self.allCases.first(where: {
            $0.rawValue == token || $0.rawValue.replacingOccurrences(of: " ", with: "_") == token
        }) ?? .plastic
    }
}

enum MaterialFinish: String, CaseIterable, Hashable {
    case matte
    case satin
    case glossy
    case polished
    case brushed
    case beadBlasted = "bead-blasted"
    case anodized
    case cast

    static func parse(_ rawValue: String) -> MaterialFinish {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return Self.allCases.first(where: { $0.rawValue == token }) ?? .satin
    }
}

enum RoughnessPattern: String, CaseIterable, Hashable {
    case smooth
    case orangePeel = "orange-peel"
    case brushed
    case machined
    case stippled
    case hammered

    static func parse(_ rawValue: String) -> RoughnessPattern {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return Self.allCases.first(where: { $0.rawValue == token }) ?? .smooth
    }
}

struct Material3D: Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var roughness: Double
    var metalness: Double
    var specular: Double
    var clearcoat: Double
    var normal: Double
    var textureScale: Double
    var roughnessVariation: Double
    var anisotropy: Double
    var surfaceType: String
    var finish: String
    var roughnessPattern: String

    init(
        r: Double,
        g: Double,
        b: Double,
        roughness: Double,
        metalness: Double,
        specular: Double = 0.5,
        clearcoat: Double = 0.08,
        normal: Double = 0.22,
        textureScale: Double = 1.0,
        roughnessVariation: Double = 0.16,
        anisotropy: Double = 0.0,
        surfaceType: String = "plastic",
        finish: String = "satin",
        roughnessPattern: String = "smooth"
    ) {
        self.r = r
        self.g = g
        self.b = b
        self.roughness = roughness
        self.metalness = metalness
        self.specular = specular
        self.clearcoat = clearcoat
        self.normal = normal
        self.textureScale = textureScale
        self.roughnessVariation = roughnessVariation
        self.anisotropy = anisotropy
        self.surfaceType = surfaceType
        self.finish = finish
        self.roughnessPattern = roughnessPattern
    }

    var resolvedSurfaceType: MaterialSurfaceType { .parse(surfaceType) }
    var resolvedFinish: MaterialFinish { .parse(finish) }
    var resolvedPattern: RoughnessPattern { .parse(roughnessPattern) }

    static let `default` = Material3D(r: 0.72, g: 0.72, b: 0.78, roughness: 0.35, metalness: 0.0)
}

// MARK: - Point3D

struct Point3D: Equatable, Hashable {
    var x, y, z: Double

    static let zero = Point3D(x: 0, y: 0, z: 0)

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }

    func translated(dx: Double = 0, dy: Double = 0, dz: Double = 0) -> Point3D {
        Point3D(x: x + dx, y: y + dy, z: z + dz)
    }

    func scaled(by f: Double) -> Point3D { Point3D(x: x * f, y: y * f, z: z * f) }

    func rotatedZ(angle: Double) -> Point3D {
        let c = cos(angle), s = sin(angle)
        return Point3D(x: x * c - y * s, y: x * s + y * c, z: z)
    }

    func rotated(angle: Double, axis: Point3D) -> Point3D {
        let len = sqrt(axis.x*axis.x + axis.y*axis.y + axis.z*axis.z)
        guard len > 1e-10 else { return self }
        let kx = axis.x/len, ky = axis.y/len, kz = axis.z/len
        let c = cos(angle), s = sin(angle), t = 1 - c
        let dot = kx*x + ky*y + kz*z
        return Point3D(
            x: x*c + (ky*z - kz*y)*s + kx*dot*t,
            y: y*c + (kz*x - kx*z)*s + ky*dot*t,
            z: z*c + (kx*y - ky*x)*s + kz*dot*t
        )
    }

    static func + (l: Point3D, r: Point3D) -> Point3D { Point3D(x: l.x+r.x, y: l.y+r.y, z: l.z+r.z) }
    static func - (l: Point3D, r: Point3D) -> Point3D { Point3D(x: l.x-r.x, y: l.y-r.y, z: l.z-r.z) }
    static func * (l: Point3D, r: Double)  -> Point3D { l.scaled(by: r) }
}

// MARK: - GeometricShape

enum GeometricShape: Equatable {
    case point(Point3D)
    case line(Point3D, Point3D)
    case polyline([Point3D])
    case polygon([Point3D])               // closed
    case surfaceStrip([Point3D], [Point3D]) // loft between two sampled curves
    case circle(center: Point3D, radius: Double)
    case sphere(center: Point3D, radius: Double)
    case box(Point3D, Point3D)            // min, max corners
    case cylinder(center: Point3D, radius: Double, height: Double)
    case cone(center: Point3D, radius: Double, height: Double)
    case torus(center: Point3D, majorRadius: Double, minorRadius: Double)
    case label(String, Point3D)
    /// Wraps any shape with a custom PBR material (used by the realistic renderer).
    indirect case painted(GeometricShape, Material3D)

    func applyingMaterial(_ material: Material3D) -> GeometricShape {
        switch self {
        case .painted(let inner, _):
            return .painted(inner, material)
        default:
            return .painted(self, material)
        }
    }

    func translated(dx: Double = 0, dy: Double = 0, dz: Double = 0) -> GeometricShape {
        switch self {
        case .point(let p):                      return .point(p.translated(dx:dx,dy:dy,dz:dz))
        case .line(let a, let b):                return .line(a.translated(dx:dx,dy:dy,dz:dz), b.translated(dx:dx,dy:dy,dz:dz))
        case .polyline(let pts):                 return .polyline(pts.map { $0.translated(dx:dx,dy:dy,dz:dz) })
        case .polygon(let pts):                  return .polygon(pts.map  { $0.translated(dx:dx,dy:dy,dz:dz) })
        case .surfaceStrip(let a, let b):        return .surfaceStrip(
            a.map { $0.translated(dx:dx,dy:dy,dz:dz) },
            b.map { $0.translated(dx:dx,dy:dy,dz:dz) }
        )
        case .circle(let c, let r):              return .circle(center: c.translated(dx:dx,dy:dy,dz:dz), radius: r)
        case .sphere(let c, let r):              return .sphere(center: c.translated(dx:dx,dy:dy,dz:dz), radius: r)
        case .box(let mn, let mx):               return .box(mn.translated(dx:dx,dy:dy,dz:dz), mx.translated(dx:dx,dy:dy,dz:dz))
        case .cylinder(let c, let r, let h):     return .cylinder(center: c.translated(dx:dx,dy:dy,dz:dz), radius: r, height: h)
        case .cone(let c, let r, let h):         return .cone(center: c.translated(dx:dx,dy:dy,dz:dz), radius: r, height: h)
        case .torus(let c, let maj, let min):    return .torus(center: c.translated(dx:dx,dy:dy,dz:dz), majorRadius: maj, minorRadius: min)
        case .label(let t, let p):               return .label(t, p.translated(dx:dx,dy:dy,dz:dz))
        case .painted(let inner, let mat):       return .painted(inner.translated(dx:dx,dy:dy,dz:dz), mat)
        }
    }

    func scaled(by f: Double) -> GeometricShape {
        switch self {
        case .point(let p):                      return .point(p.scaled(by: f))
        case .line(let a, let b):                return .line(a.scaled(by:f), b.scaled(by:f))
        case .polyline(let pts):                 return .polyline(pts.map { $0.scaled(by:f) })
        case .polygon(let pts):                  return .polygon(pts.map  { $0.scaled(by:f) })
        case .surfaceStrip(let a, let b):        return .surfaceStrip(
            a.map { $0.scaled(by:f) },
            b.map { $0.scaled(by:f) }
        )
        case .circle(let c, let r):              return .circle(center: c.scaled(by:f), radius: r * f)
        case .sphere(let c, let r):              return .sphere(center: c.scaled(by:f), radius: r * f)
        case .box(let mn, let mx):               return .box(mn.scaled(by:f), mx.scaled(by:f))
        case .cylinder(let c, let r, let h):     return .cylinder(center: c.scaled(by:f), radius: r * f, height: h * f)
        case .cone(let c, let r, let h):         return .cone(center: c.scaled(by:f), radius: r * f, height: h * f)
        case .torus(let c, let maj, let min):    return .torus(center: c.scaled(by:f), majorRadius: maj * f, minorRadius: min * f)
        case .label(let t, let p):               return .label(t, p.scaled(by:f))
        case .painted(let inner, let mat):       return .painted(inner.scaled(by:f), mat)
        }
    }

    func rotatedZ(angle: Double) -> GeometricShape {
        rotated(angle: angle, axis: Point3D(x: 0, y: 0, z: 1))
    }

    func rotated(angle: Double, axis: Point3D) -> GeometricShape {
        switch self {
        case .point(let p):                      return .point(p.rotated(angle:angle, axis:axis))
        case .line(let a, let b):                return .line(a.rotated(angle:angle, axis:axis), b.rotated(angle:angle, axis:axis))
        case .polyline(let pts):                 return .polyline(pts.map { $0.rotated(angle:angle, axis:axis) })
        case .polygon(let pts):                  return .polygon(pts.map  { $0.rotated(angle:angle, axis:axis) })
        case .surfaceStrip(let a, let b):        return .surfaceStrip(
            a.map { $0.rotated(angle:angle, axis:axis) },
            b.map { $0.rotated(angle:angle, axis:axis) }
        )
        case .circle(let c, let r):              return .circle(center: c.rotated(angle:angle, axis:axis), radius: r)
        case .sphere(let c, let r):              return .sphere(center: c.rotated(angle:angle, axis:axis), radius: r)
        case .box(let mn, let mx):               return .box(mn.rotated(angle:angle, axis:axis), mx.rotated(angle:angle, axis:axis))
        case .cylinder(let c, let r, let h):     return .cylinder(center: c.rotated(angle:angle, axis:axis), radius: r, height: h)
        case .cone(let c, let r, let h):         return .cone(center: c.rotated(angle:angle, axis:axis), radius: r, height: h)
        case .torus(let c, let maj, let min):    return .torus(center: c.rotated(angle:angle, axis:axis), majorRadius: maj, minorRadius: min)
        case .label(let t, let p):               return .label(t, p.rotated(angle:angle, axis:axis))
        case .painted(let inner, let mat):       return .painted(inner.rotated(angle:angle, axis:axis), mat)
        }
    }
}
