import Foundation

/// Minimal ZIP archive writer producing STORED (uncompressed) entries only.
/// That's sufficient for both consumers here: 3MF (whose spec permits stored
/// entries, and every 3MF-reading slicer accepts them) and USDZ (whose spec
/// *requires* stored, byte-aligned entries — Pixar's own tool never deflates
/// either). No external dependency (Compression/libzip) needed as a result.
enum ZipWriter {
    struct Entry {
        let name: String   // forward-slash path inside the archive
        let data: Data
        /// USDZ requires each file's content to start at a 64-byte aligned
        /// offset from the start of the archive; pass true to pad for that.
        let align64: Bool

        init(name: String, data: Data, align64: Bool = false) {
            self.name = name
            self.data = data
            self.align64 = align64
        }
    }

    static func build(_ entries: [Entry]) -> Data {
        var out = BinaryWriter()
        struct LocalRecord { let name: String; let crc: UInt32; let size: UInt32; let offset: UInt32 }
        var records: [LocalRecord] = []

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let bytes = [UInt8](entry.data)
            let crc = ExportUtil.crc32(bytes)

            if entry.align64 {
                // Pad via an extra field in the local file header so the
                // *content* (not the header) lands on a 64-byte boundary,
                // matching Pixar's usdzip alignment convention.
                let headerFixedSize = 30 + nameBytes.count
                let unalignedContentStart = out.data.count + headerFixedSize
                let remainder = unalignedContentStart % 64
                let padLen = remainder == 0 ? 0 : (64 - remainder)
                // extra field must itself be at least 4 bytes to encode a
                // valid (id, size) pair when non-empty.
                let extraLen = max(padLen, 0)
                let localOffset = UInt32(out.data.count)

                out.append(UInt32(0x04034b50))       // local file header signature
                out.append(UInt16(20))                 // version needed
                out.append(UInt16(0))                   // flags
                out.append(UInt16(0))                   // compression: stored
                out.append(UInt16(0)); out.append(UInt16(0)) // mod time/date
                out.append(crc)
                out.append(UInt32(bytes.count))
                out.append(UInt32(bytes.count))
                out.append(UInt16(nameBytes.count))
                out.append(UInt16(extraLen))
                out.append(nameBytes)
                if extraLen > 0 {
                    // A padding "extra field": id 0xFFFF (vendor-reserved,
                    // ignored by readers) + payload of zero bytes.
                    if extraLen >= 4 {
                        out.append(UInt16(0xFFFF))
                        out.append(UInt16(extraLen - 4))
                        out.append([UInt8](repeating: 0, count: extraLen - 4))
                    } else {
                        out.append([UInt8](repeating: 0, count: extraLen))
                    }
                }
                out.append(bytes)
                records.append(LocalRecord(name: entry.name, crc: crc, size: UInt32(bytes.count), offset: localOffset))
            } else {
                let localOffset = UInt32(out.data.count)
                out.append(UInt32(0x04034b50))
                out.append(UInt16(20))
                out.append(UInt16(0))
                out.append(UInt16(0))
                out.append(UInt16(0)); out.append(UInt16(0))
                out.append(crc)
                out.append(UInt32(bytes.count))
                out.append(UInt32(bytes.count))
                out.append(UInt16(nameBytes.count))
                out.append(UInt16(0))
                out.append(nameBytes)
                out.append(bytes)
                records.append(LocalRecord(name: entry.name, crc: crc, size: UInt32(bytes.count), offset: localOffset))
            }
        }

        let centralStart = out.data.count
        for r in records {
            let nameBytes = Array(r.name.utf8)
            out.append(UInt32(0x02014b50))   // central directory header signature
            out.append(UInt16(20))            // version made by
            out.append(UInt16(20))            // version needed
            out.append(UInt16(0))              // flags
            out.append(UInt16(0))              // compression: stored
            out.append(UInt16(0)); out.append(UInt16(0)) // mod time/date
            out.append(r.crc)
            out.append(r.size)
            out.append(r.size)
            out.append(UInt16(nameBytes.count))
            out.append(UInt16(0))  // extra field length (central dir copy — 0 is always valid)
            out.append(UInt16(0))  // comment length
            out.append(UInt16(0))  // disk number start
            out.append(UInt16(0))  // internal attributes
            out.append(UInt32(0))  // external attributes
            out.append(r.offset)
            out.append(nameBytes)
        }
        let centralSize = out.data.count - centralStart

        out.append(UInt32(0x06054b50))  // end of central directory signature
        out.append(UInt16(0)); out.append(UInt16(0)) // disk numbers
        out.append(UInt16(records.count))
        out.append(UInt16(records.count))
        out.append(UInt32(centralSize))
        out.append(UInt32(centralStart))
        out.append(UInt16(0))  // comment length

        return out.data
    }
}
