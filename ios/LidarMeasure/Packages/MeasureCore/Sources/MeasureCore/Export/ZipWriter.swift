import Foundation

/// Minimal "stored" (uncompressed) ZIP writer.
///
/// USDZ is defined as an uncompressed zip whose file data starts on 64-byte boundaries, so the
/// USD runtime can memory-map assets in place. Each local header's extra field pads the data to
/// the requested alignment. With `alignment: 1` this is a plain zip (used for the OBJ bundle).
public struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let headerOffset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []
    public let alignment: Int

    public init(alignment: Int = 1) {
        precondition(alignment >= 1)
        self.alignment = alignment
    }

    public enum ZipError: Error {
        case tooLarge
        case invalidName
    }

    public mutating func addFile(name: String, contents: Data) throws {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count < 0xFFFF else { throw ZipError.invalidName }
        guard contents.count < Int(UInt32.max), data.count + contents.count < Int(UInt32.max) - 4096 else { throw ZipError.tooLarge }

        let headerOffset = data.count
        let fixedHeader = 30
        var padding = 0
        if alignment > 1 {
            let unpadded = headerOffset + fixedHeader + nameBytes.count
            padding = (alignment - unpadded % alignment) % alignment
            // An extra field needs at least a 4-byte header, so 1–3 bytes of padding can't be
            // expressed; push to the next boundary instead.
            if padding > 0 && padding < 4 { padding += alignment }
        }

        let crc = CRC32.checksum(contents)
        let size = UInt32(contents.count)

        data.appendLE(UInt32(0x04034B50))  // local file header signature
        data.appendLE(UInt16(20))          // version needed to extract (2.0)
        data.appendLE(UInt16(0))           // general purpose flags
        data.appendLE(UInt16(0))           // compression: stored
        data.appendLE(UInt16(0))           // mod time 00:00
        data.appendLE(UInt16(0x0021))      // mod date 1980-01-01
        data.appendLE(crc)
        data.appendLE(size)                // compressed size
        data.appendLE(size)                // uncompressed size
        data.appendLE(UInt16(nameBytes.count))
        data.appendLE(UInt16(padding))
        data.append(contentsOf: nameBytes)
        if padding > 0 {
            data.appendLE(UInt16(0x1986))  // private padding header id (as used by Pixar's usdzip)
            data.appendLE(UInt16(padding - 4))
            data.append(Data(count: padding - 4))
        }
        assert(alignment == 1 || data.count % alignment == 0)
        data.append(contents)
        entries.append(Entry(name: nameBytes, crc: crc, size: size, headerOffset: UInt32(headerOffset)))
    }

    /// Appends the central directory and returns the complete archive.
    public func finalize() -> Data {
        var out = data
        let directoryOffset = out.count
        for e in entries {
            out.appendLE(UInt32(0x02014B50)) // central directory header signature
            out.appendLE(UInt16(20))         // version made by
            out.appendLE(UInt16(20))         // version needed
            out.appendLE(UInt16(0))          // flags
            out.appendLE(UInt16(0))          // compression
            out.appendLE(UInt16(0))          // time
            out.appendLE(UInt16(0x0021))     // date
            out.appendLE(e.crc)
            out.appendLE(e.size)
            out.appendLE(e.size)
            out.appendLE(UInt16(e.name.count))
            out.appendLE(UInt16(0))          // extra length
            out.appendLE(UInt16(0))          // comment length
            out.appendLE(UInt16(0))          // disk number start
            out.appendLE(UInt16(0))          // internal attributes
            out.appendLE(UInt32(0))          // external attributes
            out.appendLE(e.headerOffset)
            out.append(contentsOf: e.name)
        }
        let directorySize = out.count - directoryOffset
        out.appendLE(UInt32(0x06054B50))     // end of central directory
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directorySize))
        out.appendLE(UInt32(directoryOffset))
        out.appendLE(UInt16(0))
        return out
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    /// Appends raw little-endian scalars from an array of trivially copyable values.
    mutating func appendRaw<T>(_ array: [T]) {
        array.withUnsafeBytes { append(contentsOf: $0) }
    }
}
