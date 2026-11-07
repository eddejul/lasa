import Compression
import Foundation

/// Läser zipfiler, till exempel EPUB. Klarar okomprimerade och deflatepackade filer.
/// Zip64, kryptering och andra packmetoder stöds inte, de förekommer nästan aldrig i EPUB.
struct ZipArchive {

    struct Entry {
        let path: String
        let method: Int
        let flags: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool {
            path.hasSuffix("/")
        }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        self.data = data
        self.entries = try ZipArchive.readCentralDirectory(in: data)
    }

    func entry(named path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Innehållet i en fil i arkivet.
    func contents(of entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw BookError.unsupportedArchive }
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, Self.uint32(data, header) == 0x04034b50 else {
            throw BookError.damagedArchive
        }
        let start = header + 30 + Self.uint16(data, header + 26) + Self.uint16(data, header + 28)
        let end = start + entry.compressedSize
        guard start <= end, end <= data.count else { throw BookError.damagedArchive }

        switch entry.method {
        case 0:
            return data.subdata(in: start..<end)
        case 8:
            return try Self.inflate(data, range: start..<end, expectedSize: entry.uncompressedSize)
        default:
            throw BookError.unsupportedArchive
        }
    }

    /// Packar upp alla filer i en mapp. Sökvägar som försöker ta sig ut ur mappen hoppas över.
    func extractAll(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            guard let relative = Self.safeRelativePath(entry.path) else { continue }
            let target = directory.appendingPathComponent(relative, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try autoreleasepool {
                try contents(of: entry).write(to: target)
            }
        }
    }

    /// En sökväg i arkivet som relativ sökväg, eller nil om den försöker gå uppåt med "..".
    static func safeRelativePath(_ path: String) -> String? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        var clean: [String] = []
        for part in parts {
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                return nil
            }
            clean.append(part)
        }
        return clean.isEmpty ? nil : clean.joined(separator: "/")
    }

    // MARK: Internt

    private static func readCentralDirectory(in data: Data) throws -> [Entry] {
        let count = data.count
        guard count >= 22 else { throw BookError.notAnArchive }

        // Slutet på den centrala katalogen ligger sist i filen, före en eventuell kommentar.
        var endRecord = -1
        var position = count - 22
        let lowest = max(0, count - 22 - 0xFFFF)
        while position >= lowest {
            if data[position] == 0x50, uint32(data, position) == 0x06054b50 {
                endRecord = position
                break
            }
            position -= 1
        }
        guard endRecord >= 0 else { throw BookError.notAnArchive }

        let total = uint16(data, endRecord + 10)
        let directorySize = uint32(data, endRecord + 12)
        let directoryOffset = uint32(data, endRecord + 16)
        guard total != 0xFFFF, directoryOffset != 0xFFFFFFFF else { throw BookError.unsupportedArchive }
        guard directoryOffset + directorySize <= count else { throw BookError.damagedArchive }

        var entries: [Entry] = []
        entries.reserveCapacity(total)
        var offset = directoryOffset
        for _ in 0..<total {
            guard offset + 46 <= count, uint32(data, offset) == 0x02014b50 else { throw BookError.damagedArchive }
            let flags = uint16(data, offset + 8)
            let method = uint16(data, offset + 10)
            let compressed = uint32(data, offset + 20)
            let uncompressed = uint32(data, offset + 24)
            let nameLength = uint16(data, offset + 28)
            let extraLength = uint16(data, offset + 30)
            let commentLength = uint16(data, offset + 32)
            let localOffset = uint32(data, offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength <= count else { throw BookError.damagedArchive }

            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            entries.append(Entry(path: name,
                                 method: method,
                                 flags: flags,
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 localHeaderOffset: localOffset))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ data: Data, range: Range<Int>, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        let capacity = expectedSize + 64
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                // COMPRESSION_ZLIB är rå deflate utan zlibhuvud, precis som i zipfiler.
                return compression_decode_buffer(destinationBase, capacity,
                                                 sourceBase + range.lowerBound, range.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw BookError.damagedArchive }
        output.count = written
        return output
    }

    private static func uint16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
}
