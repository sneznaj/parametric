import Foundation

// MARK: - Shared formatting/util helpers for the 3D exporters

enum ExportUtil {

    /// Compact, locale-independent float formatting shared by every
    /// text-based exporter (OBJ/PLY-ascii/Collada/FBX-ascii/USD/STEP/IGES).
    static func num(_ v: Double, decimals: Int = 6) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%.1f", v)
        }
        return String(format: "%.\(decimals)f", v)
    }

    static func face(_ p: Point3D, decimals: Int = 6) -> String {
        "\(num(p.x, decimals: decimals)) \(num(p.y, decimals: decimals)) \(num(p.z, decimals: decimals))"
    }

    /// XML-escapes text for Collada/USD/etc. attribute or element content.
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// STEP/IGES-safe single-line string literal (backslash/quote escaped,
    /// control characters stripped).
    static func stepString(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }
        return String(String.UnicodeScalarView(cleaned))
            .replacingOccurrences(of: "'", with: "''")
    }

    static let isoTimestamp: String = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }()

    /// A filesystem/identifier-safe name for use as a mesh/node/material name.
    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped)
        return result.isEmpty ? "Shape" : result
    }

    /// CRC-32 (IEEE 802.3), used by the ZIP writer for 3MF/USDZ entries.
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Little-endian binary writer, shared by STL/PLY/GLB/USDZ

struct BinaryWriter {
    private(set) var data = Data()

    mutating func append(_ v: UInt8) { data.append(v) }

    mutating func append(_ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func append(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func append(_ v: Int32) { append(UInt32(bitPattern: v)) }

    mutating func append(_ v: Float) {
        var le = v.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func append(_ other: Data) { data.append(other) }

    /// Appends raw ASCII text with no terminator.
    mutating func append(ascii s: String) {
        data.append(contentsOf: Array(s.utf8))
    }

    /// Pads with zero bytes until `data.count` is a multiple of `alignment`.
    mutating func pad(to alignment: Int, with byte: UInt8 = 0) {
        let remainder = data.count % alignment
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: byte, count: alignment - remainder))
        }
    }
}
