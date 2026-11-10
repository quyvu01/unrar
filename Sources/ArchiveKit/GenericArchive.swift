import CArchive
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads and extracts ZIP, 7z, TAR (plain or compressed with gzip, bzip2, xz,
/// lzma, zstd, lz4 …), single compressed files (.gz, .bz2, .xz …), ISO, CAB,
/// CPIO, AR, LHA and XAR archives using libarchive.
///
/// Split archives named `name.7z.001`, `name.7z.002` … (or `.zip.001`) are
/// read as one archive when opened from any part.
public struct GenericArchive: ArchiveReader {
    public let url: URL
    /// All parts of the archive, in order (one URL for normal archives).
    public let volumes: [URL]

    public init(url: URL) {
        let volumes = GenericArchive.volumes(for: url)
        self.volumes = volumes
        self.url = volumes.first ?? url
    }

    /// Version of the libarchive library in use, e.g. "3.7.2".
    public static var libraryVersion: String {
        String(cString: archive_version_string()).replacingOccurrences(of: "libarchive ", with: "")
    }

    /// Finds the parts of a split archive (`.001`, `.002` …).
    public static func volumes(for url: URL) -> [URL] {
        let name = url.lastPathComponent
        guard let range = name.range(of: #"\.\d{3}$"#, options: .regularExpression) else { return [url] }
        let stem = String(name[..<range.lowerBound])
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        var parts: [URL] = []
        var n = 1
        while n < 1000 {
            let candidate = folder.appendingPathComponent(stem + String(format: ".%03d", n))
            guard fm.fileExists(atPath: candidate.path) else { break }
            parts.append(candidate)
            n += 1
        }
        return parts.isEmpty ? [url] : parts
    }

    private var archiveSize: UInt64 {
        volumes.reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return total + size
        }
    }

    // MARK: - Listing

    public func readInfo(password: String? = nil) throws -> ArchiveInfo {
        try listing(password: password).info
    }

    /// The listing, plus whether this is a single compressed file without stored size.
    private func listing(password: String?) throws -> (info: ArchiveInfo, isRaw: Bool) {
        let reader = try Reader(volumes: volumes, password: password)
        defer { reader.close() }

        var entries: [ArchiveEntry] = []
        var encrypted = false
        while let raw = try reader.nextHeader() {
            if let entry = reader.makeEntry(raw, index: entries.count, archiveURL: url) {
                entries.append(entry)
                encrypted = encrypted || entry.isEncrypted
            }
            try reader.skipData()
        }
        let info = ArchiveInfo(
            url: url,
            entries: entries,
            isSolid: false,
            isMultiVolume: volumes.count > 1,
            hasEncryptedHeaders: reader.headersEncrypted,
            comment: nil,
            formatLabel: reader.formatLabel(),
            hasPackedSizes: false,
            isRAR: false,
            archiveSize: archiveSize
        )
        return (info, reader.isRaw)
    }

    // MARK: - Extraction

    @discardableResult
    public func extract(paths: Set<String>? = nil,
                        to destination: URL,
                        password: String? = nil,
                        options: ExtractionOptions = ExtractionOptions(),
                        progress: ((ExtractionProgress) -> Bool)? = nil) throws -> ExtractionResult {
        try run(paths: paths, destination: destination, password: password, options: options, progress: progress)
    }

    public func test(password: String? = nil,
                     progress: ((ExtractionProgress) -> Bool)? = nil) throws {
        _ = try run(paths: nil, destination: nil, password: password, options: ExtractionOptions(), progress: progress)
    }

    private func run(paths: Set<String>?,
                     destination: URL?,
                     password: String?,
                     options: ExtractionOptions,
                     progress: ((ExtractionProgress) -> Bool)?) throws -> ExtractionResult {
        let (info, isRaw) = try listing(password: password)
        let selected = info.entries.filter { RARArchive.matches($0.path, paths) }
        let selectedFiles = selected.filter { !$0.isDirectory }
        // Single compressed files (.gz, .xz …) do not store the original size:
        // measure progress on the compressed input instead.
        let sizesKnown = !isRaw
        let totalBytes = sizesKnown ? selectedFiles.reduce(0) { $0 + $1.uncompressedSize } : info.archiveSize
        let reporter = ProgressBox(
            state: ExtractionProgress(bytesProcessed: 0, totalBytes: totalBytes, filesProcessed: 0,
                                      totalFiles: selected.count, currentPath: nil),
            callback: progress
        )

        let fm = FileManager.default
        if let destination { try createDirectory(destination) }

        let reader = try Reader(volumes: volumes, password: password)
        defer { reader.close() }

        var result = ExtractionResult()
        var reservedNames = Set<String>()
        var written: [String: URL] = [:]   // archive path -> extracted file (for hard links)
        var directoryDates: [(URL, Date)] = []
        var index = 0

        while let raw = try reader.nextHeader() {
            guard let entry = reader.makeEntry(raw, index: index, archiveURL: url) else {
                try reader.skipData()
                continue
            }
            index += 1
            guard RARArchive.matches(entry.path, paths) else {
                try reader.skipData()
                continue
            }

            reporter.begin(path: entry.path)
            if !reporter.shouldContinue { throw ArchiveError.cancelled }
            let onData: (Int) -> Bool = { count in
                sizesKnown ? reporter.add(bytes: Int64(count)) : reporter.set(bytes: reader.inputBytes)
            }

            guard let destination else {
                // Test: decompress and discard.
                if !entry.isDirectory { try reader.readData(entry: entry, into: nil, onData: onData) }
                reporter.finishFile()
                continue
            }
            guard let relative = PathSanitizer.relativePath(for: entry.path, options: options) else {
                try reader.skipData()
                reporter.finishFile()
                continue
            }
            var target = destination.appendingPathComponent(relative, isDirectory: entry.isDirectory)

            if entry.isDirectory {
                try createDirectory(target)
                if !result.extracted.contains(target) { result.extracted.append(target) }
                if let date = entry.modificationDate { directoryDates.append((target, date)) }
                try reader.skipData()
                reporter.finishFile()
                continue
            }

            let exists = fm.fileExists(atPath: target.path) || reservedNames.contains(target.path)
                || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            if exists {
                switch options.overwrite {
                case .overwrite:
                    try? fm.removeItem(at: target)
                case .skip:
                    result.skipped.append(entry.path)
                    try reader.skipData()
                    if sizesKnown { reporter.add(bytes: Int64(entry.uncompressedSize), report: false) }
                    reporter.finishFile()
                    continue
                case .rename:
                    target = RARArchive.uniqueURL(for: target, reserved: reservedNames)
                }
            }

            try createDirectory(target.deletingLastPathComponent())
            reservedNames.insert(target.path)

            if let linkTarget = reader.symlinkTarget(raw) {
                // Only relative links that stay inside the destination are recreated.
                if Self.isSafeSymlink(linkTarget, at: relative) {
                    try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                    result.extracted.append(target)
                }
                try reader.skipData()
                reporter.finishFile()
                continue
            }

            if let hardlink = reader.hardlinkTarget(raw) {
                let normalized = PathSanitizer.safeComponents(of: hardlink).joined(separator: "/")
                if let source = written[normalized] {
                    try? fm.copyItem(at: source, to: target)
                    result.extracted.append(target)
                }
                try reader.skipData()
                reporter.finishFile()
                continue
            }

            guard fm.createFile(atPath: target.path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: target.path) else {
                throw ArchiveError.cannotCreate(path: target.path)
            }
            do {
                try reader.readData(entry: entry, into: handle, onData: onData)
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: target)
                if !reporter.shouldContinue { throw ArchiveError.cancelled }
                throw error
            }
            if !reporter.shouldContinue {
                try? fm.removeItem(at: target)
                throw ArchiveError.cancelled
            }

            var attributes: [FileAttributeKey: Any] = [:]
            if let date = entry.modificationDate { attributes[.modificationDate] = date }
            if let mode = reader.permissions(raw) { attributes[.posixPermissions] = NSNumber(value: mode & 0o755 | 0o600) }
            if !attributes.isEmpty { try? fm.setAttributes(attributes, ofItemAtPath: target.path) }

            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.uint64Value ?? entry.uncompressedSize
            written[entry.path] = target
            result.extracted.append(target)
            result.bytesWritten += size
            reporter.finishFile()
        }

        // Folder dates last, since writing files inside changes them.
        for (folder, date) in directoryDates.reversed() {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }
        return result
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.cannotCreate(path: url.path)
        }
    }

    /// A link at `relativePath` pointing to `target` must not leave the destination.
    static func isSafeSymlink(_ target: String, at relativePath: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        var depth = relativePath.split(separator: "/").count - 1
        for component in target.split(separator: "/") {
            if component == ".." {
                depth -= 1
                if depth < 0 { return false }
            } else if component != "." {
                depth += 1
            }
        }
        return true
    }
}

// MARK: - libarchive reader

private final class Reader {
    let raw: OpaquePointer
    private let previousLocale: locale_t?
    private var paths: [UnsafeMutablePointer<CChar>?] = []
    private(set) var headersEncrypted = false
    private var firstHeaderRead = false

    init(volumes: [URL], password: String?) throws {
        for volume in volumes {
            guard FileManager.default.isReadableFile(atPath: volume.path) else { throw ArchiveError.cannotOpen }
        }
        guard let pointer = archive_read_new() else { throw ArchiveError.outOfMemory }
        raw = pointer
        previousLocale = carchive_begin_utf8()

        // Formats and filters are enabled one by one on purpose: "all" would
        // also enable mtree (which reads files from the local disk) and
        // filters that shell out to external programs.
        archive_read_support_format_7zip(raw)
        archive_read_support_format_ar(raw)
        archive_read_support_format_cab(raw)
        archive_read_support_format_cpio(raw)
        archive_read_support_format_iso9660(raw)
        archive_read_support_format_lha(raw)
        archive_read_support_format_rar(raw)
        archive_read_support_format_rar5(raw)
        archive_read_support_format_tar(raw)
        archive_read_support_format_xar(raw)
        archive_read_support_format_zip(raw)
        archive_read_support_format_raw(raw)

        archive_read_support_filter_gzip(raw)
        archive_read_support_filter_bzip2(raw)
        archive_read_support_filter_xz(raw)
        archive_read_support_filter_lzma(raw)
        archive_read_support_filter_lzip(raw)
        archive_read_support_filter_compress(raw)
        archive_read_support_filter_zstd(raw)
        archive_read_support_filter_lz4(raw)
        archive_read_support_filter_uu(raw)

        if let password, !password.isEmpty {
            archive_read_add_passphrase(raw, password)
        }

        paths = volumes.map { strdup($0.path) } + [nil]
        let rc = paths.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                archive_read_open_filenames(raw, $0, 64 * 1024)
            }
        }
        if rc != ARCHIVE_OK {
            let error = translateError(rc)
            close()
            if case .failed = error { throw ArchiveError.notAnArchive }
            throw error
        }
    }

    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        archive_read_free(raw)
        for path in paths { free(path) }
        paths = []
        carchive_restore_locale(previousLocale)
    }

    deinit { close() }

    var formatCode: Int32 { archive_format(raw) }
    var isRaw: Bool { formatCode & 0xFF0000 == 0x90000 }
    /// Compressed bytes consumed so far.
    var inputBytes: UInt64 { UInt64(max(0, archive_filter_bytes(raw, -1))) }

    /// Returns the next entry, or nil at the end of the archive.
    func nextHeader() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let rc = archive_read_next_header(raw, &entry)
        if rc == ARCHIVE_EOF { return nil }
        if rc == ARCHIVE_OK || rc == ARCHIVE_WARN {
            if !firstHeaderRead {
                firstHeaderRead = true
                // The raw reader accepts any file; only allow it on top of a
                // decompression filter (.gz, .xz …), otherwise it is not an archive.
                if isRaw, archive_filter_count(raw) <= 1 || archive_filter_code(raw, 0) == 0 {
                    throw ArchiveError.notAnArchive
                }
            }
            return entry
        }
        if !firstHeaderRead, message.localizedCaseInsensitiveContains("unrecognized archive format") {
            throw ArchiveError.notAnArchive
        }
        if message.localizedCaseInsensitiveContains("encrypt") || message.localizedCaseInsensitiveContains("passphrase") {
            headersEncrypted = true
        }
        throw translateError(rc)
    }

    func skipData() throws {
        let rc = archive_read_data_skip(raw)
        if rc != ARCHIVE_OK && rc != ARCHIVE_WARN && rc != ARCHIVE_EOF { throw translateError(rc) }
    }

    /// Decompresses the current entry, writing it to `handle` (or discarding it).
    func readData(entry: ArchiveEntry, into handle: FileHandle?, onData: (Int) -> Bool) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: Int64 = 0
        var position: Int64 = 0
        while true {
            let rc = archive_read_data_block(raw, &buffer, &size, &offset)
            if rc == ARCHIVE_EOF { break }
            if rc == ARCHIVE_WARN, message.localizedCaseInsensitiveContains("crc") {
                throw entry.isEncrypted ? ArchiveError.wrongPassword : ArchiveError.corruptData(path: entry.path)
            }
            if rc != ARCHIVE_OK && rc != ARCHIVE_WARN { throw translateError(rc, entry: entry) }
            if let handle, let buffer, size > 0 {
                do {
                    if offset != position { try handle.seek(toOffset: UInt64(offset)) }
                    try handle.write(contentsOf: Data(bytes: buffer, count: size))
                } catch {
                    throw ArchiveError.writeFailed(path: entry.path)
                }
                position = offset + Int64(size)
            }
            if !onData(size) { throw ArchiveError.cancelled }
        }
        // Sparse files can end with a hole.
        if let handle, entry.uncompressedSize > 0, UInt64(position) < entry.uncompressedSize {
            try? handle.truncate(atOffset: entry.uncompressedSize)
        }
    }

    // MARK: Entries

    func makeEntry(_ e: OpaquePointer, index: Int, archiveURL: URL) -> ArchiveEntry? {
        var path = Self.decodePath(utf8: archive_entry_pathname_utf8(e), raw: archive_entry_pathname(e))
        if isRaw {
            // Single compressed file: name it after the archive ("notes.txt.gz" -> "notes.txt").
            path = Self.rawName(for: archiveURL)
        }
        path = PathSanitizer.safeComponents(of: path).joined(separator: "/")
        guard !path.isEmpty else { return nil }

        let type = archive_entry_filetype(e) & 0o170000
        let isDirectory = type == 0o040000
        let isSymlink = type == 0o120000
        let isHardlink = archive_entry_hardlink(e) != nil
        let size: UInt64 = archive_entry_size_is_set(e) != 0 ? UInt64(max(0, archive_entry_size(e))) : 0
        var date: Date?
        if archive_entry_mtime_is_set(e) != 0 {
            let seconds = archive_entry_mtime(e)
            if seconds > 0 {
                date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(archive_entry_mtime_nsec(e)) / 1e9)
            }
        }
        let encrypted = archive_entry_is_encrypted(e) != 0
        return ArchiveEntry(
            index: index,
            path: path,
            uncompressedSize: isDirectory ? 0 : size,
            compressedSize: 0,
            isDirectory: isDirectory,
            isEncrypted: encrypted,
            isLink: isSymlink || isHardlink,
            modificationDate: date
        )
    }

    func symlinkTarget(_ e: OpaquePointer) -> String? {
        guard archive_entry_filetype(e) & 0o170000 == 0o120000 else { return nil }
        let target = Self.decodePath(utf8: archive_entry_symlink_utf8(e), raw: archive_entry_symlink(e))
        return target.isEmpty ? nil : target
    }

    func hardlinkTarget(_ e: OpaquePointer) -> String? {
        let target = Self.decodePath(utf8: archive_entry_hardlink_utf8(e), raw: archive_entry_hardlink(e))
        return target.isEmpty ? nil : target
    }

    func permissions(_ e: OpaquePointer) -> UInt16? {
        let mode = UInt16(truncatingIfNeeded: archive_entry_perm(e))
        return mode == 0 ? nil : mode
    }

    static func decodePath(utf8: UnsafePointer<CChar>?, raw: UnsafePointer<CChar>?) -> String {
        if let utf8 { return String(cString: utf8) }
        guard let raw else { return "" }
        if let string = String(validatingUTF8: raw) { return string }
        // Old ZIP files from Windows store names in the DOS code page.
        let data = Data(bytes: raw, count: strlen(raw))
        #if canImport(Darwin)
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        if let string = String(data: data, encoding: dos) { return string }
        #endif
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static let compressedSuffixes = ["gz", "gzip", "bz2", "bzip2", "xz", "lzma", "lz", "zst", "lz4", "z", "uu"]

    static func rawName(for url: URL) -> String {
        var name = url.lastPathComponent
        if let range = name.range(of: #"\.\d{3}$"#, options: .regularExpression) { name.removeSubrange(range) }
        let ext = (name as NSString).pathExtension.lowercased()
        if compressedSuffixes.contains(ext) {
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? "data" : name
    }

    // MARK: Format

    func formatLabel() -> String {
        let base: String
        switch formatCode & 0xFF0000 {
        case 0x10000: base = "CPIO"
        case 0x30000: base = "TAR"
        case 0x40000: base = "ISO 9660"
        case 0x50000: base = "ZIP"
        case 0x70000: base = "AR"
        case 0x90000: base = ""
        case 0xA0000: base = "XAR"
        case 0xB0000: base = "LHA"
        case 0xC0000: base = "CAB"
        case 0xD0000, 0x100000: base = "RAR"
        case 0xE0000: base = "7Z"
        default: base = String(cString: archive_format_name(raw))
        }
        let filter: String?
        switch archive_filter_count(raw) > 1 ? archive_filter_code(raw, 0) : 0 {
        case 1: filter = "GZ"
        case 2: filter = "BZ2"
        case 3: filter = "Z"
        case 5: filter = "LZMA"
        case 6: filter = "XZ"
        case 7: filter = "UU"
        case 9: filter = "LZ"
        case 13: filter = "LZ4"
        case 14: filter = "ZST"
        default: filter = nil
        }
        switch (base.isEmpty, filter) {
        case (true, let filter?): return filter
        case (true, nil): return "RAW"
        case (false, let filter?): return "\(base).\(filter)"
        case (false, nil): return base
        }
    }

    // MARK: Errors

    var message: String {
        archive_error_string(raw).map { String(cString: $0) } ?? ""
    }

    func translateError(_ code: Int32, entry: ArchiveEntry? = nil) -> ArchiveError {
        let text = message
        let lower = text.lowercased()
        if lower.contains("passphrase required") || lower.contains("passphrase is required") {
            return .passwordRequired
        }
        if lower.contains("incorrect passphrase") || lower.contains("wrong passphrase") {
            return .wrongPassword
        }
        if lower.contains("encrypt") && (lower.contains("unsupported") || lower.contains("not supported")) {
            return .unsupportedEncryption
        }
        if lower.contains("decryption is unsupported") || lower.contains("crypto library") {
            return .unsupportedEncryption
        }
        if lower.contains("crc") || lower.contains("checksum") {
            return entry?.isEncrypted == true ? .wrongPassword : .corruptData(path: entry?.path)
        }
        if lower.contains("truncated") || lower.contains("premature end") || lower.contains("damaged") {
            return .brokenArchive
        }
        if lower.contains("unrecognized archive format") {
            return .notAnArchive
        }
        if archive_errno(raw) == ENOMEM { return .outOfMemory }
        return .failed(message: text)
    }
}
