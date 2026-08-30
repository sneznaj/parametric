import Foundation
import UniformTypeIdentifiers

// MARK: - UTType for .svg files

extension UTType {
    static var svg: UTType {
        UTType(filenameExtension: "svg") ?? .xml
    }
}

// MARK: - SVG Exporter

/// Generates an SVG document from an array of GeometricShape values,
/// converting world-space coordinates to SVG canvas coordinates
/// (Y-axis is flipped so positive Y maps up in the world but down in SVG).
enum SVGExporter {

    /// Export shapes to an SVG string.
    /// - Parameters:
    ///   - shapes: The geometry to export — only 2D-friendly types are rendered.
    ///   - padding: World-space padding added around the bounding box.
    /// - Returns: A complete SVG document as a string.
    static func export(
        shapes: [GeometricShape],
        padding: Double = 2.0
    ) -> String {
        let flattened = shapes.flatMap { flattenShape($0) }
        guard !flattened.isEmpty else {
            return emptySVG()
        }

        let bounds = computeBounds(flattened.map(\.shape), padding: padding)
        let vb = svgViewBox(from: bounds)

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg"
             viewBox="\(vb.x) \(vb.y) \(vb.w) \(vb.h)"
             width="\(formatNumber(vb.w))"
             height="\(formatNumber(vb.h))">

        """

        // Background
        svg += "  <rect x=\"\(formatNumber(bounds.minX))\" y=\"\(formatNumber(bounds.minY))\" "
        svg += "width=\"\(formatNumber(bounds.maxX - bounds.minX))\" "
        svg += "height=\"\(formatNumber(bounds.maxY - bounds.minY))\" "
        svg += "fill=\"#171717\"/>\n"

        for item in flattened {
            svg += renderShape(item.shape, style: item.style, bounds: bounds) + "\n"
        }

        svg += "</svg>\n"
        return svg
    }

    // MARK: - Internal

    private struct StyledShape {
        let shape: GeometricShape
        let style: FlattenedStyle
    }

    private struct FlattenedStyle {
        var strokeR: Double = 1.0
        var strokeG: Double = 1.0
        var strokeB: Double = 1.0
        var strokeThickness: Double = 1.5
        var fillR: Double = 0.3
        var fillG: Double = 0.3
        var fillB: Double = 0.3
        var fillEnabled: Bool = false
    }

    /// Unwrap .painted and .styled2D wrappers, collecting style along the way.
    private static func flattenShape(_ shape: GeometricShape) -> [StyledShape] {
        var style = FlattenedStyle()

        func walk(_ s: GeometricShape) -> [GeometricShape] {
            switch s {
            case .painted(let inner, let material):
                style.strokeR = material.r
                style.strokeG = material.g
                style.strokeB = material.b
                style.fillR = material.r
                style.fillG = material.g
                style.fillB = material.b
                style.fillEnabled = true
                return walk(inner)
            case .styled2D(let inner, let s2d):
                style.strokeR = s2d.strokeR
                style.strokeG = s2d.strokeG
                style.strokeB = s2d.strokeB
                style.strokeThickness = s2d.strokeThickness
                style.fillR = s2d.fillR
                style.fillG = s2d.fillG
                style.fillB = s2d.fillB
                style.fillEnabled = s2d.fillEnabled
                return walk(inner)
            default:
                return [s]
            }
        }

        return walk(shape).map { StyledShape(shape: $0, style: style) }
    }

    // MARK: - Bounds

    private struct Bounds {
        var minX: Double = .infinity
        var minY: Double = .infinity
        var maxX: Double = -.infinity
        var maxY: Double = -.infinity

        mutating func expand(_ x: Double, _ y: Double) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    private static func computeBounds(_ shapes: [GeometricShape], padding: Double) -> Bounds {
        var bounds = Bounds()

        for shape in shapes {
            for (x, y) in points(for: shape) {
                bounds.expand(x, y)
            }
        }

        // If no points found, use a default
        if bounds.minX == .infinity {
            bounds = Bounds(minX: -10, minY: -10, maxX: 10, maxY: 10)
        }

        // Flip Y: SVG Y increases downward, our world Y increases upward
        let minY = bounds.minY
        let maxY = bounds.maxY
        bounds.minY = -maxY - padding
        bounds.maxY = -minY + padding

        bounds.minX -= padding
        bounds.maxX += padding

        return bounds
    }

    private static func svgViewBox(from bounds: Bounds) -> (x: Double, y: Double, w: Double, h: Double) {
        let w = bounds.maxX - bounds.minX
        let h = bounds.maxY - bounds.minY
        return (bounds.minX, bounds.minY, w, h)
    }

    // MARK: - Point extraction for bounds

    private static func points(for shape: GeometricShape) -> [(Double, Double)] {
        switch shape {
        case .point(let p):                return [(p.x, p.y)]
        case .line(let a, let b):          return [(a.x, a.y), (b.x, b.y)]
        case .polyline(let pts):           return pts.map { ($0.x, $0.y) }
        case .polygon(let pts):            return pts.map { ($0.x, $0.y) }
        case .circle(let c, let r):        return [
            (c.x + r, c.y), (c.x - r, c.y), (c.x, c.y + r), (c.x, c.y - r)
        ]
        case .spline(let cps, let degree, let closed):
            return CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed).map { ($0.x, $0.y) }
        case .styled2D(let inner, _):      return points(for: inner)
        case .painted(let inner, _):       return points(for: inner)
        default:
            return []
        }
    }

    // MARK: - Rendering

    private static func renderShape(_ shape: GeometricShape, style: FlattenedStyle, bounds: Bounds) -> String {
        switch shape {
        case .point(let p):
            return renderCircle(cx: p.x, cy: p.y, r: max(2, style.strokeThickness * 1.5),
                                style: style, fillEnabled: true)

        case .line(let a, let b):
            return renderLine(x1: a.x, y1: a.y, x2: b.x, y2: b.y, style: style)

        case .polyline(let pts):
            return renderPolyline(pts.map { ($0.x, $0.y) }, style: style, closePath: false)

        case .polygon(let pts):
            return renderPolyline(pts.map { ($0.x, $0.y) }, style: style, closePath: true)

        case .circle(let c, let r):
            let fillStyle = FlattenedStyle(
                strokeR: style.strokeR, strokeG: style.strokeG, strokeB: style.strokeB,
                strokeThickness: style.strokeThickness,
                fillR: style.fillR, fillG: style.fillG, fillB: style.fillB,
                fillEnabled: true
            )
            return renderCircle(cx: c.x, cy: c.y, r: r, style: fillStyle, fillEnabled: true)

        case .spline(let cps, let degree, let closed):
            let pts = CurveKernel.sampleSpline(controlPoints: cps, degree: degree, closed: closed)
            return renderPolyline(pts.map { ($0.x, $0.y) }, style: style, closePath: false)

        case .styled2D(let inner, _):
            return renderShape(inner, style: style, bounds: bounds)

        case .painted(let inner, _):
            return renderShape(inner, style: style, bounds: bounds)

        default:
            return ""
        }
    }

    // MARK: - SVG element helpers

    private static func svgY(_ y: Double) -> Double {
        // Flip Y: SVG Y increases downward, our world Y increases upward
        return -y
    }

    private static func formatNumber(_ value: Double, decimals: Int = 4) -> String {
        let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        return String(format: "%.\(decimals)g", rounded)
    }

    private static func colorHex(r: Double, g: Double, b: Double) -> String {
        let ri = max(0, min(255, Int((r * 255).rounded())))
        let gi = max(0, min(255, Int((g * 255).rounded())))
        let bi = max(0, min(255, Int((b * 255).rounded())))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    private static func renderLine(x1: Double, y1: Double, x2: Double, y2: Double,
                                    style: FlattenedStyle) -> String {
        let color = colorHex(r: style.strokeR, g: style.strokeG, b: style.strokeB)
        return """
          <line x1="\(formatNumber(x1))" y1="\(formatNumber(svgY(y1)))" \
        x2="\(formatNumber(x2))" y2="\(formatNumber(svgY(y2)))" \
        stroke="\(color)" stroke-width="\(formatNumber(style.strokeThickness))" \
        stroke-linecap="round"/>
        """
    }

    private static func renderPolyline(_ pts: [(Double, Double)], style: FlattenedStyle,
                                        closePath: Bool) -> String {
        guard pts.count >= (closePath ? 1 : 2) else { return "" }

        let color = colorHex(r: style.strokeR, g: style.strokeG, b: style.strokeB)
        let fillColor = colorHex(r: style.fillR, g: style.fillG, b: style.fillB)

        var d = "M \(formatNumber(pts[0].0)) \(formatNumber(svgY(pts[0].1)))"
        for (x, y) in pts.dropFirst() {
            d += " L \(formatNumber(x)) \(formatNumber(svgY(y)))"
        }
        if closePath {
            d += " Z"
        }

        var attrs = "d=\"\(d)\" "
        attrs += "stroke=\"\(color)\" stroke-width=\"\(formatNumber(style.strokeThickness))\" "
        attrs += "stroke-linejoin=\"round\" stroke-linecap=\"round\" "
        if style.fillEnabled {
            attrs += "fill=\"\(fillColor)\" fill-opacity=\"0.92\" "
        } else {
            attrs += "fill=\"none\" "
        }

        return "  <path \(attrs)/>"
    }

    private static func renderCircle(cx: Double, cy: Double, r: Double,
                                      style: FlattenedStyle, fillEnabled: Bool) -> String {
        let color = colorHex(r: style.strokeR, g: style.strokeG, b: style.strokeB)
        let fillColor = colorHex(r: style.fillR, g: style.fillG, b: style.fillB)
        let fill = fillEnabled
            ? "fill=\"\(fillColor)\" fill-opacity=\"0.92\" "
            : "fill=\"none\" "

        return """
          <circle cx="\(formatNumber(cx))" cy="\(formatNumber(svgY(cy)))" \
        r="\(formatNumber(r))" \
        stroke="\(color)" stroke-width="\(formatNumber(style.strokeThickness))" \
        \(fill)/>
        """
    }

    private static func emptySVG() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg"
             viewBox="-50 -50 100 100"
             width="100" height="100">
          <rect width="100" height="100" fill="#171717"/>
          <text x="0" y="5" fill="#555" font-family="system-ui" font-size="8"
                text-anchor="middle" dominant-baseline="central">Empty</text>
        </svg>
        """
    }
}
