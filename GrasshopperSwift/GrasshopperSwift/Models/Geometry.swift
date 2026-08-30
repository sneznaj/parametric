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

/// Which Filament material (and BRDF) backs a Material3D. `metallicRoughness`
/// is the default `lit`-model studio_pbr.mat path (metallic-roughness +
/// clear coat + anisotropy + sheen, all stackable). `subsurface` routes to
/// the dedicated studio_subsurface.mat/`subsurface` shading model instead —
/// a different BRDF/BTDF blend for translucent materials (wax, marble,
/// alabaster) that doesn't have clear coat/anisotropy/sheen.
enum MaterialShadingFamily: String, CaseIterable, Hashable, Codable {
    case metallicRoughness
    case subsurface

    static func parse(_ rawValue: String) -> MaterialShadingFamily {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.allCases.first(where: { $0.rawValue.lowercased() == token }) ?? .metallicRoughness
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

struct Material3D: Equatable, Hashable, Codable {
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
    var shadingFamily: String
    // Sheen (cloth/velvet fuzz layer, stacks on top of metallic-roughness —
    // see studio_pbr.mat). Black (0,0,0) sheenColor is an exact no-op.
    var sheenR: Double
    var sheenG: Double
    var sheenB: Double
    var sheenRoughness: Double
    // Subsurface-scattering approximation (studio_subsurface.mat only —
    // ignored by the metallicRoughness family).
    var subsurfaceR: Double
    var subsurfaceG: Double
    var subsurfaceB: Double
    var subsurfacePower: Double
    var thickness: Double
    // Dielectric transmission (glass/liquid) and emission — Ultra Realistic
    // (path tracer) only; Filament's studio_pbr/studio_subsurface materials
    // don't currently expose either, so these are no-ops there.
    var transmission: Double
    var ior: Double
    var emissionR: Double
    var emissionG: Double
    var emissionB: Double
    var emissionStrength: Double

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
        roughnessPattern: String = "smooth",
        shadingFamily: String = "metallicRoughness",
        sheenR: Double = 0,
        sheenG: Double = 0,
        sheenB: Double = 0,
        sheenRoughness: Double = 0.3,
        subsurfaceR: Double = 1,
        subsurfaceG: Double = 1,
        subsurfaceB: Double = 1,
        subsurfacePower: Double = 12.234,
        thickness: Double = 1.0,
        transmission: Double = 0,
        ior: Double = 1.5,
        emissionR: Double = 0,
        emissionG: Double = 0,
        emissionB: Double = 0,
        emissionStrength: Double = 0
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
        self.shadingFamily = shadingFamily
        self.sheenR = sheenR
        self.sheenG = sheenG
        self.sheenB = sheenB
        self.sheenRoughness = sheenRoughness
        self.subsurfaceR = subsurfaceR
        self.subsurfaceG = subsurfaceG
        self.subsurfaceB = subsurfaceB
        self.subsurfacePower = subsurfacePower
        self.thickness = thickness
        self.transmission = transmission
        self.ior = ior
        self.emissionR = emissionR
        self.emissionG = emissionG
        self.emissionB = emissionB
        self.emissionStrength = emissionStrength
    }

    // Custom decoding so `.ghs` files saved before shadingFamily/sheen/
    // subsurface existed still load: missing keys fall back to the same
    // defaults as the memberwise init above, instead of failing to decode.
    // (Encoding stays auto-synthesized — Decodable/Encodable synthesis are
    // independent, so providing this init(from:) doesn't require a manual
    // encode(to:).)
    private enum CodingKeys: String, CodingKey {
        case r, g, b, roughness, metalness, specular, clearcoat, normal
        case textureScale, roughnessVariation, anisotropy
        case surfaceType, finish, roughnessPattern
        case shadingFamily, sheenR, sheenG, sheenB, sheenRoughness
        case subsurfaceR, subsurfaceG, subsurfaceB, subsurfacePower, thickness
        case transmission, ior, emissionR, emissionG, emissionB, emissionStrength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decode(Double.self, forKey: .r)
        g = try c.decode(Double.self, forKey: .g)
        b = try c.decode(Double.self, forKey: .b)
        roughness = try c.decode(Double.self, forKey: .roughness)
        metalness = try c.decode(Double.self, forKey: .metalness)
        specular = try c.decodeIfPresent(Double.self, forKey: .specular) ?? 0.5
        clearcoat = try c.decodeIfPresent(Double.self, forKey: .clearcoat) ?? 0.08
        normal = try c.decodeIfPresent(Double.self, forKey: .normal) ?? 0.22
        textureScale = try c.decodeIfPresent(Double.self, forKey: .textureScale) ?? 1.0
        roughnessVariation = try c.decodeIfPresent(Double.self, forKey: .roughnessVariation) ?? 0.16
        anisotropy = try c.decodeIfPresent(Double.self, forKey: .anisotropy) ?? 0.0
        surfaceType = try c.decodeIfPresent(String.self, forKey: .surfaceType) ?? "plastic"
        finish = try c.decodeIfPresent(String.self, forKey: .finish) ?? "satin"
        roughnessPattern = try c.decodeIfPresent(String.self, forKey: .roughnessPattern) ?? "smooth"
        shadingFamily = try c.decodeIfPresent(String.self, forKey: .shadingFamily) ?? "metallicRoughness"
        sheenR = try c.decodeIfPresent(Double.self, forKey: .sheenR) ?? 0
        sheenG = try c.decodeIfPresent(Double.self, forKey: .sheenG) ?? 0
        sheenB = try c.decodeIfPresent(Double.self, forKey: .sheenB) ?? 0
        sheenRoughness = try c.decodeIfPresent(Double.self, forKey: .sheenRoughness) ?? 0.3
        subsurfaceR = try c.decodeIfPresent(Double.self, forKey: .subsurfaceR) ?? 1
        subsurfaceG = try c.decodeIfPresent(Double.self, forKey: .subsurfaceG) ?? 1
        subsurfaceB = try c.decodeIfPresent(Double.self, forKey: .subsurfaceB) ?? 1
        subsurfacePower = try c.decodeIfPresent(Double.self, forKey: .subsurfacePower) ?? 12.234
        thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? 1.0
        transmission = try c.decodeIfPresent(Double.self, forKey: .transmission) ?? 0
        ior = try c.decodeIfPresent(Double.self, forKey: .ior) ?? 1.5
        emissionR = try c.decodeIfPresent(Double.self, forKey: .emissionR) ?? 0
        emissionG = try c.decodeIfPresent(Double.self, forKey: .emissionG) ?? 0
        emissionB = try c.decodeIfPresent(Double.self, forKey: .emissionB) ?? 0
        emissionStrength = try c.decodeIfPresent(Double.self, forKey: .emissionStrength) ?? 0
    }

    var resolvedSurfaceType: MaterialSurfaceType { .parse(surfaceType) }
    var resolvedFinish: MaterialFinish { .parse(finish) }
    var resolvedPattern: RoughnessPattern { .parse(roughnessPattern) }
    var resolvedShadingFamily: MaterialShadingFamily { .parse(shadingFamily) }

    /// Ordinal of `resolvedPattern` within `RoughnessPattern.allCases`, sent to the
    /// shader as a float and switched on there to pick the procedural micro-detail
    /// character (smooth/orange-peel/brushed/machined/stippled/hammered).
    var patternIndex: Int {
        RoughnessPattern.allCases.firstIndex(of: resolvedPattern) ?? 0
    }

    static let `default` = Material3D(r: 0.72, g: 0.72, b: 0.78, roughness: 0.35, metalness: 0.0)

    /// Fuzzy-equality identity for render batching. Two materials that are
    /// "mathematically connected" — driven by the same upstream parameters
    /// but reaching an Output through different arithmetic — can differ by a
    /// float epsilon while representing the same intended material. Quantizing
    /// every channel before hashing lets such materials collapse onto a single
    /// shared GPU material instance instead of spawning visually-identical
    /// duplicates.
    struct RenderKey: Hashable {
        private static let precision = 4096.0  // ~1/4096 quantization step per channel

        private let r, g, b: Int
        private let roughness, metalness, specular, clearcoat, normal: Int
        private let textureScale, roughnessVariation, anisotropy: Int
        private let surfaceType, finish, roughnessPattern, shadingFamily: String
        private let sheenR, sheenG, sheenB, sheenRoughness: Int
        private let subsurfaceR, subsurfaceG, subsurfaceB, subsurfacePower, thickness: Int
        private let transmission, ior, emissionR, emissionG, emissionB, emissionStrength: Int

        init(_ material: Material3D) {
            func q(_ v: Double) -> Int { Int((v * Self.precision).rounded()) }
            r = q(material.r); g = q(material.g); b = q(material.b)
            roughness = q(material.roughness)
            metalness = q(material.metalness)
            specular = q(material.specular)
            clearcoat = q(material.clearcoat)
            normal = q(material.normal)
            textureScale = q(material.textureScale)
            roughnessVariation = q(material.roughnessVariation)
            anisotropy = q(material.anisotropy)
            surfaceType = material.surfaceType
            finish = material.finish
            roughnessPattern = material.roughnessPattern
            // Must be part of the key: a metallicRoughness and a subsurface
            // Material3D back entirely different Filament materials — sharing
            // a cached instance across families would attach the wrong
            // material's uniforms (or crash) rather than just look wrong.
            shadingFamily = material.shadingFamily
            sheenR = q(material.sheenR); sheenG = q(material.sheenG); sheenB = q(material.sheenB)
            sheenRoughness = q(material.sheenRoughness)
            subsurfaceR = q(material.subsurfaceR)
            subsurfaceG = q(material.subsurfaceG)
            subsurfaceB = q(material.subsurfaceB)
            subsurfacePower = q(material.subsurfacePower)
            thickness = q(material.thickness)
            transmission = q(material.transmission)
            ior = q(material.ior)
            emissionR = q(material.emissionR); emissionG = q(material.emissionG); emissionB = q(material.emissionB)
            emissionStrength = q(material.emissionStrength)
        }
    }

    var renderKey: RenderKey { RenderKey(self) }
}

// MARK: - Shape2DStyle

struct Shape2DStyle: Equatable, Hashable, Codable {
    var strokeR: Double; var strokeG: Double; var strokeB: Double
    var strokeThickness: Double
    var fillR: Double; var fillG: Double; var fillB: Double
    var fillEnabled: Bool

    static let `default` = Shape2DStyle(
        strokeR: 1.0, strokeG: 1.0, strokeB: 1.0, strokeThickness: 2.0,
        fillR: 0.8, fillG: 0.8, fillB: 0.8, fillEnabled: false
    )
}

// MARK: - Point3D

struct Point3D: Equatable, Hashable, Codable {
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

enum GeometricShape: Equatable, Codable {
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
    /// General triangle mesh: flat index list, stride 3, CCW winding.
    case mesh(vertices: [Point3D], triangleIndices: [Int])
    /// Non-rational B-spline curve defined by its control points and degree
    /// (clamped/open by default; `closed` wraps the control polygon for a
    /// periodic curve). `CurveKernel` evaluates it via De Boor's algorithm —
    /// see `CurveKernel.sampleSpline`/`interpolatedSpline`.
    case spline(controlPoints: [Point3D], degree: Int, closed: Bool)
    case label(String, Point3D)
    /// Wraps any shape with 2D style (stroke thickness, fill, colors).
    indirect case styled2D(GeometricShape, Shape2DStyle)
    /// Wraps any shape with a custom PBR material (used by the realistic renderer).
    indirect case painted(GeometricShape, Material3D)

    func applyingMaterial(_ material: Material3D) -> GeometricShape {
        switch self {
        case .painted(let inner, _):
            return .painted(inner, material)
        case .styled2D(let inner, let style):
            return .styled2D(inner.applyingMaterial(material), style)
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
        case .mesh(let verts, let tris):         return .mesh(vertices: verts.map { $0.translated(dx:dx,dy:dy,dz:dz) }, triangleIndices: tris)
        case .spline(let cps, let deg, let closed): return .spline(controlPoints: cps.map { $0.translated(dx:dx,dy:dy,dz:dz) }, degree: deg, closed: closed)
        case .label(let t, let p):               return .label(t, p.translated(dx:dx,dy:dy,dz:dz))
        case .styled2D(let inner, let style):    return .styled2D(inner.translated(dx:dx,dy:dy,dz:dz), style)
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
        case .mesh(let verts, let tris):         return .mesh(vertices: verts.map { $0.scaled(by:f) }, triangleIndices: tris)
        case .spline(let cps, let deg, let closed): return .spline(controlPoints: cps.map { $0.scaled(by:f) }, degree: deg, closed: closed)
        case .label(let t, let p):               return .label(t, p.scaled(by:f))
        case .styled2D(let inner, let style):    return .styled2D(inner.scaled(by:f), style)
        case .painted(let inner, let mat):       return .painted(inner.scaled(by:f), mat)
        }
    }

    func rotatedZ(angle: Double) -> GeometricShape {
        rotated(angle: angle, axis: Point3D(x: 0, y: 0, z: 1))
    }

    /// Applies an arbitrary point transform to every vertex/control point.
    /// Used by transform nodes (non-uniform scale, mirror, orient) that
    /// don't fit `translated`/`scaled`/`rotated`'s simpler parameterizations.
    /// Curved analytic primitives (sphere/box/cylinder/cone/torus) are
    /// tessellated to a `.mesh` first since a general point map can't stay
    /// expressible in their center/radius parameterization.
    func mapped(_ transform: (Point3D) -> Point3D) -> GeometricShape {
        switch self {
        case .point(let p):                      return .point(transform(p))
        case .line(let a, let b):                return .line(transform(a), transform(b))
        case .polyline(let pts):                 return .polyline(pts.map(transform))
        case .polygon(let pts):                  return .polygon(pts.map(transform))
        case .surfaceStrip(let a, let b):        return .surfaceStrip(a.map(transform), b.map(transform))
        case .circle(let c, let r):
            let pts = (0...64).map { i -> Point3D in
                let a = Double(i) / 64 * 2 * Double.pi
                return Point3D(x: c.x + r * cos(a), y: c.y + r * sin(a), z: c.z)
            }
            return .polyline(pts.map(transform))
        case .sphere, .box, .cylinder, .cone, .torus:
            guard let md = MeshKernel.meshData(from: self) else { return self }
            return .mesh(vertices: md.vertices.map(transform), triangleIndices: md.triangleIndices)
        case .mesh(let verts, let tris):
            return .mesh(vertices: verts.map(transform), triangleIndices: tris)
        case .spline(let cps, let deg, let closed):
            // A general point map doesn't commute with B-spline blending, so
            // (like sphere/box/cylinder/cone/torus above) sample to a polyline
            // first rather than mapping control points directly.
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: deg, closed: closed)
            return .polyline(pts.map(transform))
        case .label(let t, let p):               return .label(t, transform(p))
        case .styled2D(let inner, let style):    return .styled2D(inner.mapped(transform), style)
        case .painted(let inner, let mat):       return .painted(inner.mapped(transform), mat)
        }
    }

    /// True when this shape (looking through any `.painted` wrapper) originated from the
    /// 2D shape pipeline (`.styled2D`) rather than the 3D geometry pipeline.
    var isStyled2D: Bool {
        switch self {
        case .styled2D:                    return true
        case .painted(let inner, _):       return inner.isStyled2D
        default:                           return false
        }
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
        case .mesh(let verts, let tris):         return .mesh(vertices: verts.map { $0.rotated(angle:angle, axis:axis) }, triangleIndices: tris)
        case .spline(let cps, let deg, let closed): return .spline(controlPoints: cps.map { $0.rotated(angle:angle, axis:axis) }, degree: deg, closed: closed)
        case .label(let t, let p):               return .label(t, p.rotated(angle:angle, axis:axis))
        case .styled2D(let inner, let style):    return .styled2D(inner.rotated(angle:angle, axis:axis), style)
        case .painted(let inner, let mat):       return .painted(inner.rotated(angle:angle, axis:axis), mat)
        }
    }

    // MARK: - Codable

    private enum ShapeType: String, Codable {
        case point, line, polyline, polygon, surfaceStrip
        case circle, sphere, box, cylinder, cone, torus, mesh
        case spline
        case label, styled2D, painted
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case point, lineA, lineB
        case points
        case surfaceA, surfaceB
        case center, radius
        case minCorner, maxCorner
        case height
        case majorRadius, minorRadius
        case meshVertices, meshTriangleIndices
        case splineControlPoints, splineDegree, splineClosed
        case text, location
        case shape, style
        case material
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let p):
            try container.encode(ShapeType.point, forKey: .type)
            try container.encode(p, forKey: .point)
        case .line(let a, let b):
            try container.encode(ShapeType.line, forKey: .type)
            try container.encode(a, forKey: .lineA)
            try container.encode(b, forKey: .lineB)
        case .polyline(let pts):
            try container.encode(ShapeType.polyline, forKey: .type)
            try container.encode(pts, forKey: .points)
        case .polygon(let pts):
            try container.encode(ShapeType.polygon, forKey: .type)
            try container.encode(pts, forKey: .points)
        case .surfaceStrip(let a, let b):
            try container.encode(ShapeType.surfaceStrip, forKey: .type)
            try container.encode(a, forKey: .surfaceA)
            try container.encode(b, forKey: .surfaceB)
        case .circle(let c, let r):
            try container.encode(ShapeType.circle, forKey: .type)
            try container.encode(c, forKey: .center)
            try container.encode(r, forKey: .radius)
        case .sphere(let c, let r):
            try container.encode(ShapeType.sphere, forKey: .type)
            try container.encode(c, forKey: .center)
            try container.encode(r, forKey: .radius)
        case .box(let mn, let mx):
            try container.encode(ShapeType.box, forKey: .type)
            try container.encode(mn, forKey: .minCorner)
            try container.encode(mx, forKey: .maxCorner)
        case .cylinder(let c, let r, let h):
            try container.encode(ShapeType.cylinder, forKey: .type)
            try container.encode(c, forKey: .center)
            try container.encode(r, forKey: .radius)
            try container.encode(h, forKey: .height)
        case .cone(let c, let r, let h):
            try container.encode(ShapeType.cone, forKey: .type)
            try container.encode(c, forKey: .center)
            try container.encode(r, forKey: .radius)
            try container.encode(h, forKey: .height)
        case .torus(let c, let maj, let min):
            try container.encode(ShapeType.torus, forKey: .type)
            try container.encode(c, forKey: .center)
            try container.encode(maj, forKey: .majorRadius)
            try container.encode(min, forKey: .minorRadius)
        case .mesh(let verts, let tris):
            try container.encode(ShapeType.mesh, forKey: .type)
            try container.encode(verts, forKey: .meshVertices)
            try container.encode(tris, forKey: .meshTriangleIndices)
        case .spline(let cps, let degree, let closed):
            try container.encode(ShapeType.spline, forKey: .type)
            try container.encode(cps, forKey: .splineControlPoints)
            try container.encode(degree, forKey: .splineDegree)
            try container.encode(closed, forKey: .splineClosed)
        case .label(let t, let p):
            try container.encode(ShapeType.label, forKey: .type)
            try container.encode(t, forKey: .text)
            try container.encode(p, forKey: .location)
        case .styled2D(let inner, let s):
            try container.encode(ShapeType.styled2D, forKey: .type)
            try container.encode(inner, forKey: .shape)
            try container.encode(s, forKey: .style)
        case .painted(let inner, let mat):
            try container.encode(ShapeType.painted, forKey: .type)
            try container.encode(inner, forKey: .shape)
            try container.encode(mat, forKey: .material)
        }
    }

    /// Pull the painted material off a shape if any. Default to a neutral grey.
    func material() -> Material3D {
        switch self {
        case .painted(_, let mat):
            return mat
        case .styled2D(let inner, _):
            return inner.material()
        default:
            return .default
        }
    }

    /// Strip painted/styled wrappers to get the underlying geometry shape.
    func unwrapForRendering() -> GeometricShape {
        switch self {
        case .painted(let inner, _): return inner.unwrapForRendering()
        case .styled2D(let inner, _): return inner.unwrapForRendering()
        default: return self
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ShapeType.self, forKey: .type)
        switch type {
        case .point:
            let p = try container.decode(Point3D.self, forKey: .point)
            self = .point(p)
        case .line:
            let a = try container.decode(Point3D.self, forKey: .lineA)
            let b = try container.decode(Point3D.self, forKey: .lineB)
            self = .line(a, b)
        case .polyline:
            let pts = try container.decode([Point3D].self, forKey: .points)
            self = .polyline(pts)
        case .polygon:
            let pts = try container.decode([Point3D].self, forKey: .points)
            self = .polygon(pts)
        case .surfaceStrip:
            let a = try container.decode([Point3D].self, forKey: .surfaceA)
            let b = try container.decode([Point3D].self, forKey: .surfaceB)
            self = .surfaceStrip(a, b)
        case .circle:
            let c = try container.decode(Point3D.self, forKey: .center)
            let r = try container.decode(Double.self, forKey: .radius)
            self = .circle(center: c, radius: r)
        case .sphere:
            let c = try container.decode(Point3D.self, forKey: .center)
            let r = try container.decode(Double.self, forKey: .radius)
            self = .sphere(center: c, radius: r)
        case .box:
            let mn = try container.decode(Point3D.self, forKey: .minCorner)
            let mx = try container.decode(Point3D.self, forKey: .maxCorner)
            self = .box(mn, mx)
        case .cylinder:
            let c = try container.decode(Point3D.self, forKey: .center)
            let r = try container.decode(Double.self, forKey: .radius)
            let h = try container.decode(Double.self, forKey: .height)
            self = .cylinder(center: c, radius: r, height: h)
        case .cone:
            let c = try container.decode(Point3D.self, forKey: .center)
            let r = try container.decode(Double.self, forKey: .radius)
            let h = try container.decode(Double.self, forKey: .height)
            self = .cone(center: c, radius: r, height: h)
        case .torus:
            let c = try container.decode(Point3D.self, forKey: .center)
            let maj = try container.decode(Double.self, forKey: .majorRadius)
            let min = try container.decode(Double.self, forKey: .minorRadius)
            self = .torus(center: c, majorRadius: maj, minorRadius: min)
        case .mesh:
            let verts = try container.decode([Point3D].self, forKey: .meshVertices)
            let tris = try container.decode([Int].self, forKey: .meshTriangleIndices)
            self = .mesh(vertices: verts, triangleIndices: tris)
        case .spline:
            let cps = try container.decode([Point3D].self, forKey: .splineControlPoints)
            let degree = try container.decode(Int.self, forKey: .splineDegree)
            let closed = try container.decode(Bool.self, forKey: .splineClosed)
            self = .spline(controlPoints: cps, degree: degree, closed: closed)
        case .label:
            let t = try container.decode(String.self, forKey: .text)
            let p = try container.decode(Point3D.self, forKey: .location)
            self = .label(t, p)
        case .styled2D:
            let inner = try container.decode(GeometricShape.self, forKey: .shape)
            let s = try container.decode(Shape2DStyle.self, forKey: .style)
            self = .styled2D(inner, s)
        case .painted:
            let inner = try container.decode(GeometricShape.self, forKey: .shape)
            let mat = try container.decode(Material3D.self, forKey: .material)
            self = .painted(inner, mat)
        }
    }
}

// MARK: - RenderConfig (Phase D: drives Filament view post-processing from graph)

/// Tone-mapping operator. Maps header integer modes to Filament's ToneMapper
/// subclasses (see filament_createColorGrading's toneMapper parameter).
enum ToneMapper: Int, CaseIterable, Codable {
    case linear      = 0
    case aces        = 1
    case acesLegacy  = 2
    case filmic      = 3
    case pbrNeutral  = 4
    case agx         = 5

    static func parse(_ rawValue: String) -> ToneMapper {
        let token = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch token {
        case "linear":                  return .linear
        case "aces":                    return .aces
        case "aceslegacy":              return .acesLegacy
        case "filmic":                  return .filmic
        case "pbrneutral", "neutral":   return .pbrNeutral
        case "agx":                     return .agx
        default:                        return .aces
        }
    }
}

enum BloomBlendMode: Int, CaseIterable, Codable {
    case additive     = 0
    case interpolate  = 1
}

enum SSAOQuality: Int, CaseIterable, Codable {
    case low    = 0
    case medium = 1
    case high   = 2
    case ultra  = 3
}

struct BloomConfig: Equatable, Hashable, Codable {
    var strength: Double = 0.04
    var threshold: Double = 0.9
    var anamorphism: Double = 0.0
    var levels: Int = 6
    var blendMode: BloomBlendMode = .additive
}

struct SSAOConfig: Equatable, Hashable, Codable {
    var radius: Double = 0.5
    var power: Double = 1.0
    var bias: Double = 0.001
    var intensity: Double = 0.7
    var quality: SSAOQuality = .medium
}

struct FogConfig: Equatable, Hashable, Codable {
    var distance: Double = 0.0
    var height: Double = 0.0
    var heightFalloff: Double = 1.0
    var density: Double = 0.0
    var inScatteringStart: Double = 0.0
    var colorFromIBL: Bool = true
    var r: Double = 0.7
    var g: Double = 0.75
    var b: Double = 0.85
}

struct ColorRGB: Equatable, Hashable, Codable {
    var r: Double
    var g: Double
    var b: Double
    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }
    static let white = ColorRGB(1, 1, 1)
}

/// Homogeneous global participating medium ("fog") for the path-traced
/// ("Ultra Realistic") renderer only. This is deliberately NOT the same type
/// as `FogConfig` — that one drives Filament's screen-space fog post-process,
/// while this drives real volumetric scattering/absorption in the path
/// tracer's free-flight sampling (see `PTMediumUniforms` in
/// `PathTracerShaderTypes.h`). Contributed by a "Volumetric Fog" graph node,
/// same as every other `RenderConfig` field.
struct PTVolumeConfig: Equatable, Hashable, Codable {
    var enabled: Bool = false
    var density: Double = 0.02          // extinction (sigma_t) scale, 1/world-units
    var colorR: Double = 1.0
    var colorG: Double = 1.0
    var colorB: Double = 1.0
    var anisotropy: Double = 0.0        // Henyey-Greenstein g, [-1, 1]
    var heightFalloff: Double = 0.0     // 0 = uniform fog; >0 = exponential falloff with world Y
}

/// A single point light contributed by a "Point Light" node.
struct SceneLight: Equatable, Hashable, Codable {
    var position: Point3D
    var color: ColorRGB
    var intensity: Double   // lumens, passed straight to filament_createPointLight
}

/// An arbitrary-shaped area light contributed by an "Object Light" node —
/// turns whatever geometry is wired into it into a self-illuminating light
/// for the Ultra Realistic path tracer's light tree (see PathTracerScene).
/// Carried on `RenderConfig` (like `SceneLight` above) rather than painted
/// onto the shape itself, because an Output node's "Mat" input is applied
/// uniformly to every shape reaching it — see
/// `NodeGraph.trackedShapes(for:shapes:)` — which would otherwise overwrite
/// this light's own emissive material if the shape and other objects shared
/// an Output.
struct SceneObjectLight: Equatable, Codable {
    var shapes: [GeometricShape]
    var color: ColorRGB
    var intensity: Double
}

/// Aggregate render configuration. The FilamentRenderView reads this and
/// translates each field to the matching bridge call. The Output node
/// constructs one from connected render-config nodes.
struct RenderConfig: Equatable, Codable {
    var toneMapper: ToneMapper = .aces
    var exposure: Double = 0.0          // EV stops (relative to camera)
    var whiteBalanceKelvin: Double = 6500.0
    var contrast: Double = 0.0          // [-1, 1]
    var saturation: Double = 0.0        // [-1, 1]

    var bloom: BloomConfig = BloomConfig()
    var ssao: SSAOConfig = SSAOConfig()
    var fog: FogConfig? = nil

    var sunDirection: Point3D = Point3D(x: -0.55, y: -0.72, z: 0.41)
    var sunColor: ColorRGB = ColorRGB(1.0, 0.95, 0.88)
    var sunIntensity: Double = 80_000.0

    /// Extra point lights contributed by "Point Light" nodes, in addition to
    /// the single directional sun above.
    var pointLights: [SceneLight] = []

    /// Extra area lights contributed by "Object Light" nodes — Ultra
    /// Realistic (path tracer) only, same as `pathTracerVolume` below.
    var objectLights: [SceneObjectLight] = []

    var environmentPath: String? = nil
    var skyboxPath: String? = nil

    /// Ultra Realistic (path tracer) only — see `PTVolumeConfig`.
    var pathTracerVolume: PTVolumeConfig = PTVolumeConfig()

    /// Cinematic defaults used when no render-config nodes are wired up.
    static let cinematicDefault = RenderConfig()
}

// MARK: - TrackedShape (Phase B: stable identity across evaluations)

/// Wraps a GeometricShape with a stable UUID assigned by the Output node.
/// The UUID survives across evaluations when the shape's positional slot in
/// the output stream is unchanged — letting the renderer diff entities by id
/// instead of tearing down and rebuilding geometry on every slider drag.
struct TrackedShape: Identifiable, Equatable {
    let id: UUID
    let shape: GeometricShape

    init(id: UUID = UUID(), shape: GeometricShape) {
        self.id = id
        self.shape = shape
    }
}
