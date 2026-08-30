import Foundation

/// IGES 5.3 — one bounded planar face (Type 108, Form 1 "Bounded Plane") per
/// triangle, each bounded by a closed 3-point curve (Type 106, Form 12,
/// "piecewise linear path"). This deliberately skips the newer Manifold
/// Solid B-Rep entities (Types 186/502/504/508/510/514) in favor of Type
/// 108's own native curve-bounding field — fewer, better-documented entity
/// types for the same visible result (a shaded facet per triangle), and
/// every IGES reader that supports solids at all supports Bounded Plane,
/// since it dates to the original 1980s core entity set rather than the
/// 1996 Solids extension.
enum IGESExporter {
    static func export(scene: ExportScene, fileName: String = "export.iges") -> String {
        let w = IGESWriter()
        for part in scene.parts {
            let solid = BRepBuilder.build(vertices: part.vertices, triangles: part.triangleIndices)
            emit(faces: solid.faces, vertices: solid.vertices, w: w)
        }
        return w.assemble(fileName: fileName)
    }

    private static func emit(faces: [BRepBuilder.Face], vertices: [Point3D], w: IGESWriter) {
        for face in faces {
            guard face.vertexLoop.count == 3 else { continue }
            let a = vertices[face.vertexLoop[0]]
            let b = vertices[face.vertexLoop[1]]
            let c = vertices[face.vertexLoop[2]]
            let normal = (b - a).cross(c - a).normalized
            guard normal.length > 1e-9 else { continue }

            let loopPts = [a, b, c, a]  // closed: repeat first point
            var curveParams = ["2", "\(loopPts.count)"]
            for p in loopPts { curveParams.append(contentsOf: [n(p.x), n(p.y), n(p.z)]) }
            let curveDE = w.addEntity(type: 106, form: 12, params: curveParams)

            let d = normal.dot(a)
            let planeParams = [
                n(normal.x), n(normal.y), n(normal.z), n(d),
                "\(curveDE)",
                n(a.x), n(a.y), n(a.z), "0"
            ]
            _ = w.addEntity(type: 108, form: 1, params: planeParams)
        }
    }

    private static func n(_ v: Double) -> String { ExportUtil.num(v) }
}

// MARK: - Low-level IGES 5.3 file assembly (Start/Global/Directory/Parameter/Terminate)

private final class IGESWriter {
    private var dLines: [String] = []
    private var pLines: [String] = []
    private var nextDE = 1
    private var nextP = 1

    /// Adds one entity's Directory Entry (2 fixed-width lines) and Parameter
    /// Data (N 64-column lines, comma-joined and semicolon-terminated, split
    /// at raw 64-character boundaries — legal per spec since parameter data
    /// is one continuous character stream across P-section lines). Returns
    /// this entity's Directory Entry sequence number, i.e. the pointer other
    /// entities use to reference it.
    @discardableResult
    func addEntity(type: Int, form: Int, params: [String]) -> Int {
        let deSeq = nextDE
        let firstP = nextP

        let content = params.joined(separator: ",") + ";"
        var remaining = Substring(content)
        var lineCount = 0
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(64))
            remaining = remaining.dropFirst(chunk.count)
            let padded = chunk + String(repeating: " ", count: 64 - chunk.count)
            pLines.append(padded + rjust(String(deSeq), 8) + "P" + rjust(String(nextP), 7))
            nextP += 1
            lineCount += 1
        }

        let typeField = rjust(String(type), 8)
        let zero = rjust("0", 8)
        let line1 = typeField + rjust(String(firstP), 8)
            + zero + zero + zero + zero + zero + zero
            + "00000001"
            + "D" + rjust(String(deSeq), 7)
        let line2 = typeField + zero + zero
            + rjust(String(lineCount), 8) + rjust(String(form), 8)
            + zero + zero
            + String(repeating: " ", count: 8)
            + zero
            + "D" + rjust(String(deSeq + 1), 7)

        dLines.append(line1)
        dLines.append(line2)
        nextDE += 2
        return deSeq
    }

    func assemble(fileName: String) -> String {
        var out = ""

        let startText = "Exported from GrasshopperSwift"
        out += pad72(startText) + "S" + rjust("1", 7) + "\n"

        let now = ISO8601DateFormatter()
        now.formatOptions = [.withInternetDateTime]
        let stamp = now.string(from: Date())
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: ".")
            .replacingOccurrences(of: "Z", with: "")
        let dateHollerith = hollerith(String(stamp.prefix(15)))

        let globals: [String] = [
            "1H,", "1H;",
            hollerith("GrasshopperSwift"),
            hollerith(fileName),
            hollerith("GrasshopperSwift"),
            hollerith("GrasshopperSwift"),
            "32", "38", "6", "308", "15",
            hollerith("Unspecified"),
            "1.0", "2", "2HMM", "1", "1.0",
            dateHollerith,
            "0.0001", "0.0",
            "0H", "0H",
            "11", "0",
            dateHollerith
        ]
        let globalContent = globals.joined(separator: ",") + ";"
        var remaining = Substring(globalContent)
        var gSeq = 1
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(64))
            remaining = remaining.dropFirst(chunk.count)
            out += pad72(chunk) + "G" + rjust(String(gSeq), 7) + "\n"
            gSeq += 1
        }
        let gCount = gSeq - 1

        for line in dLines { out += line + "\n" }
        for line in pLines { out += line + "\n" }

        let terminate = "S" + rjust("1", 7) + "G" + rjust(String(gCount), 7)
            + "D" + rjust(String(dLines.count), 7) + "P" + rjust(String(pLines.count), 7)
        out += pad72(terminate) + "T" + rjust("1", 7) + "\n"

        return out
    }

    private func hollerith(_ s: String) -> String { "\(s.utf8.count)H\(s)" }

    private func rjust(_ s: String, _ width: Int) -> String {
        let t = s.count > width ? String(s.suffix(width)) : s
        return String(repeating: " ", count: max(0, width - t.count)) + t
    }

    private func pad72(_ s: String) -> String {
        let t = s.count > 72 ? String(s.prefix(72)) : s
        return t + String(repeating: " ", count: max(0, 72 - t.count))
    }
}
