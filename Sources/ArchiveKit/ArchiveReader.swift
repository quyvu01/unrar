import Foundation

/// Common interface of the archive readers (RAR via UnRAR, everything else via libarchive).
public protocol ArchiveReader: Sendable {
    /// The archive file (first volume for multi-part archives).
    var url: URL { get }

    /// Reads the list of entries.
    func readInfo(password: String?) throws -> ArchiveInfo

    /// Extracts entries (`nil` = everything) to `destination`. `progress`
    /// returns `false` to cancel.
    @discardableResult
    func extract(paths: Set<String>?, to destination: URL, password: String?,
                 options: ExtractionOptions, progress: ((ExtractionProgress) -> Bool)?) throws -> ExtractionResult

    /// Decompresses everything without writing to disk.
    func test(password: String?, progress: ((ExtractionProgress) -> Bool)?) throws
}

extension RARArchive: ArchiveReader {}

/// Picks the right reader for a file and knows which files can be opened.
public enum Archives {
    /// Returns the reader for `url`: UnRAR for RAR archives, libarchive for the rest.
    public static func reader(for url: URL) -> any ArchiveReader {
        if isRAR(url) { return RARArchive(url: url) }
        return GenericArchive(url: url)
    }

    public static func isRAR(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if RARArchive.fileExtensions.contains(ext) { return true }
        if ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil { return true }
        return RARArchive.hasRARSignature(url)
    }

    /// Extensions handled by libarchive.
    public static let genericExtensions: Set<String> = [
        "zip", "zipx", "cbz", "jar", "epub",
        "7z", "cb7",
        "tar", "cbt", "tgz", "taz", "tbz", "tbz2", "tb2", "txz", "tlz", "tzst", "tlz4",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "lz", "zst", "lz4", "z",
        "iso", "cab", "cpio", "xar", "lha", "lzh", "ar", "deb",
    ]

    public static var fileExtensions: Set<String> { RARArchive.fileExtensions.union(genericExtensions) }

    /// Whether a file looks like something we can open (by extension or by content).
    public static func isSupported(_ url: URL) -> Bool {
        var ext = url.pathExtension.lowercased()
        if ext.range(of: #"^\d{3}$"#, options: .regularExpression) != nil {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        if fileExtensions.contains(ext) { return true }
        if ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil { return true }
        return hasKnownSignature(url)
    }

    /// Checks the first bytes for the magic number of a supported format.
    public static func hasKnownSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let bytes = [UInt8](handle.readData(ofLength: 512))
        let signatures: [[UInt8]] = [
            [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07],             // RAR
            [0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06], // ZIP
            [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],             // 7z
            [0x1F, 0x8B],                                     // gzip
            [0x42, 0x5A, 0x68],                               // bzip2
            [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],             // xz
            [0x28, 0xB5, 0x2F, 0xFD],                         // zstd
            [0x04, 0x22, 0x4D, 0x18],                         // lz4
            [0x4C, 0x5A, 0x49, 0x50],                         // lzip
            [0x4D, 0x53, 0x43, 0x46],                         // cab
            [0x78, 0x61, 0x72, 0x21],                         // xar
        ]
        if signatures.contains(where: { bytes.starts(with: $0) }) { return true }
        // tar: "ustar" at offset 257.
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) { return true }
        return false
    }

    /// Name for the folder that receives the files: "Photos.tar.gz" -> "Photos",
    /// "Movie.part1.rar" -> "Movie", "Backup.7z.001" -> "Backup".
    public static func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        if let range = name.range(of: #"\.\d{3}$"#, options: .regularExpression) { name.removeSubrange(range) }
        let known = fileExtensions.union(["tar"])
        for _ in 0..<2 {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, known.contains(ext) || ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil else { break }
            name = (name as NSString).deletingPathExtension
        }
        if let range = name.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.isEmpty ? "Archive" : name
    }
}
