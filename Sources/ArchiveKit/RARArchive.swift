import Foundation
import CUnrar

/// Reads and extracts RAR archives (RAR 1.5 – RAR 7, including encrypted and
/// multi-volume archives) using the bundled UnRAR library.
///
/// All methods are synchronous and potentially slow; call them from a
/// background task. A `RARArchive` value is cheap and holds no open handles.
public struct RARArchive: Sendable {
    public let url: URL

    /// - Parameter url: Any volume of the archive. For `name.partN.rar`
    ///   archives the first volume is used automatically when present.
    public init(url: URL) {
        self.url = RARArchive.firstVolume(for: url)
    }

    public static var libraryVersion: Int { Int(cunrar_version()) }

    /// File extensions recognised as RAR archives.
    public static let fileExtensions: Set<String> = ["rar", "cbr"]

    /// Returns `true` when the file starts with a RAR 1.5–4 or RAR 5+ signature.
    public static func hasRARSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8)
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        let bytes = [UInt8](data)
        return bytes.starts(with: rar5) || bytes.starts(with: rar4)
    }

    /// Maps `foo.part3.rar` to `foo.part1.rar` (or `part01`, `part001`) if it exists.
    public static func firstVolume(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard let range = name.range(of: #"\.part(\d+)\.rar$"#, options: [.regularExpression, .caseInsensitive]) else {
            return url
        }
        let digits = name[range].filter(\.isNumber)
        guard let number = Int(digits), number > 1 else { return url }
        let stem = name[..<range.lowerBound]
        let padded = String(repeating: "0", count: max(0, digits.count - 1)) + "1"
        let candidate = url.deletingLastPathComponent().appendingPathComponent("\(stem).part\(padded).rar")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
    }

    // MARK: - Listing

    /// Reads the list of entries.
    /// - Throws: `ArchiveError.passwordRequired` when the file names are encrypted
    ///   and `password` is nil, `.wrongPassword` when it is wrong.
    public func readInfo(password: String? = nil) throws -> ArchiveInfo {
        let handle = try Handle(url: url, listOnly: true, password: password)
        defer { handle.close() }

        let flags = cunrar_archive_flags(handle.raw)
        var entries: [ArchiveEntry] = []
        var header = cunrar_entry()
        while true {
            let code = cunrar_read_header(handle.raw, &header)
            if code == Int32(CUNRAR_END_ARCHIVE) { break }
            if code != Int32(CUNRAR_SUCCESS) { throw handle.error(for: code) }
            entries.append(Self.makeEntry(header, index: entries.count))
            let skip = cunrar_process(handle.raw, Int32(CUNRAR_OP_SKIP), nil)
            if skip != Int32(CUNRAR_SUCCESS) { throw handle.error(for: skip) }
        }

        return ArchiveInfo(
            url: url,
            entries: entries,
            isSolid: flags & UInt32(CUNRAR_ARC_SOLID) != 0,
            isMultiVolume: flags & UInt32(CUNRAR_ARC_VOLUME) != 0,
            hasEncryptedHeaders: flags & UInt32(CUNRAR_ARC_ENCRYPTED_HEADERS) != 0,
            isLocked: flags & UInt32(CUNRAR_ARC_LOCK) != 0,
            hasRecoveryRecord: flags & UInt32(CUNRAR_ARC_RECOVERY) != 0,
            comment: cunrar_comment(handle.raw).map { String(cString: $0) }
        )
    }

    // MARK: - Extraction

    /// Extracts entries to `destination`.
    ///
    /// - Parameters:
    ///   - paths: Paths of the entries to extract (folders include their
    ///     contents). `nil` extracts everything.
    ///   - destination: Folder that receives the files. Created if needed.
    ///   - progress: Called periodically on the extracting thread. Return
    ///     `false` to cancel.
    @discardableResult
    public func extract(paths: Set<String>? = nil,
                        to destination: URL,
                        password: String? = nil,
                        options: ExtractionOptions = ExtractionOptions(),
                        progress: ((ExtractionProgress) -> Bool)? = nil) throws -> ExtractionResult {
        try run(operation: .extract, paths: paths, destination: destination,
                password: password, options: options, progress: progress)
    }

    /// Verifies the integrity of every file without writing anything.
    public func test(password: String? = nil,
                     progress: ((ExtractionProgress) -> Bool)? = nil) throws {
        _ = try run(operation: .test, paths: nil, destination: nil,
                    password: password, options: ExtractionOptions(), progress: progress)
    }

    // MARK: - Implementation

    private enum Operation { case extract, test }

    private func run(operation: Operation,
                     paths: Set<String>?,
                     destination: URL?,
                     password: String?,
                     options: ExtractionOptions,
                     progress: ((ExtractionProgress) -> Bool)?) throws -> ExtractionResult {
        // A quick listing gives totals for the progress bar and validates the password
        // for archives with encrypted headers.
        let info = try readInfo(password: password)
        let selected = info.entries.filter { Self.matches($0.path, paths) }
        let state = ExtractionProgress(
            bytesProcessed: 0,
            totalBytes: selected.filter { !$0.isDirectory }.reduce(0) { $0 + $1.uncompressedSize },
            filesProcessed: 0,
            totalFiles: selected.count,
            currentPath: nil
        )

        let fm = FileManager.default
        if operation == .extract, let destination {
            try createDirectory(destination)
        }

        let handle = try Handle(url: url, listOnly: false, password: password)
        defer { handle.close() }

        let reporter = ProgressBox(state: state, callback: progress)
        let context = Unmanaged.passUnretained(reporter).toOpaque()
        cunrar_set_progress(handle.raw, { ctx, bytes in
            guard let ctx else { return 0 }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.add(bytes: bytes) ? 0 : 1
        }, context)

        var result = ExtractionResult()
        var header = cunrar_entry()
        var index = 0
        var reservedNames = Set<String>()

        while true {
            let code = cunrar_read_header(handle.raw, &header)
            if code == Int32(CUNRAR_END_ARCHIVE) { break }
            if code != Int32(CUNRAR_SUCCESS) { throw handle.error(for: code) }
            let entry = Self.makeEntry(header, index: index)
            index += 1

            guard Self.matches(entry.path, paths) else {
                let skip = cunrar_process(handle.raw, Int32(CUNRAR_OP_SKIP), nil)
                if skip != Int32(CUNRAR_SUCCESS) { throw handle.error(for: skip, path: entry.path) }
                continue
            }

            reporter.begin(path: entry.path)
            if !reporter.shouldContinue { throw ArchiveError.cancelled }

            switch operation {
            case .test:
                let rc = cunrar_process(handle.raw, Int32(CUNRAR_OP_TEST), nil)
                if rc != Int32(CUNRAR_SUCCESS) { throw handle.error(for: rc, path: entry.path, entry: entry) }

            case .extract:
                guard let destination,
                      let relative = PathSanitizer.relativePath(for: entry.path, options: options) else {
                    let skip = cunrar_process(handle.raw, Int32(CUNRAR_OP_SKIP), nil)
                    if skip != Int32(CUNRAR_SUCCESS) { throw handle.error(for: skip, path: entry.path) }
                    reporter.finishFile()
                    continue
                }
                var target = destination.appendingPathComponent(relative, isDirectory: entry.isDirectory)

                if entry.isDirectory {
                    try createDirectory(target)
                    if !result.extracted.contains(target) { result.extracted.append(target) }
                    let skip = cunrar_process(handle.raw, Int32(CUNRAR_OP_SKIP), nil)
                    if skip != Int32(CUNRAR_SUCCESS) { throw handle.error(for: skip, path: entry.path) }
                    reporter.finishFile()
                    continue
                }

                let exists = fm.fileExists(atPath: target.path) || reservedNames.contains(target.path)
                if exists {
                    switch options.overwrite {
                    case .overwrite:
                        try? fm.removeItem(at: target)
                    case .skip:
                        result.skipped.append(entry.path)
                        let skip = cunrar_process(handle.raw, Int32(CUNRAR_OP_SKIP), nil)
                        if skip != Int32(CUNRAR_SUCCESS) { throw handle.error(for: skip, path: entry.path) }
                        reporter.add(bytes: Int64(entry.uncompressedSize), report: false)
                        reporter.finishFile()
                        continue
                    case .rename:
                        target = Self.uniqueURL(for: target, reserved: reservedNames)
                    }
                }

                try createDirectory(target.deletingLastPathComponent())
                reservedNames.insert(target.path)
                let rc = target.path.withCString { cunrar_process(handle.raw, Int32(CUNRAR_OP_EXTRACT), $0) }
                if rc != Int32(CUNRAR_SUCCESS) {
                    // Do not leave half-written files behind.
                    try? fm.removeItem(at: target)
                    throw handle.error(for: rc, path: entry.path, entry: entry)
                }
                result.extracted.append(target)
                result.bytesWritten += entry.uncompressedSize
            }
            reporter.finishFile()
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

    static func matches(_ path: String, _ selection: Set<String>?) -> Bool {
        guard let selection else { return true }
        if selection.contains(path) { return true }
        // A selected folder includes everything below it.
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            if selection.contains(String(current)) { return true }
        }
        return false
    }

    static func uniqueURL(for url: URL, reserved: Set<String>) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) && !reserved.contains(candidate.path) { return candidate }
            n += 1
        }
    }

    static func makeEntry(_ h: cunrar_entry, index: Int) -> ArchiveEntry {
        var path = h.name.map { String(cString: $0) } ?? ""
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        return ArchiveEntry(
            index: index,
            path: path,
            uncompressedSize: h.unpacked_size,
            compressedSize: h.packed_size,
            isDirectory: h.flags & UInt32(CUNRAR_ENTRY_DIRECTORY) != 0,
            isEncrypted: h.flags & UInt32(CUNRAR_ENTRY_ENCRYPTED) != 0,
            isSolid: h.flags & UInt32(CUNRAR_ENTRY_SOLID) != 0,
            isLink: h.redirect_type != 0,
            modificationDate: h.modification_time > 0 ? Date(timeIntervalSince1970: h.modification_time) : nil,
            crc32: h.crc32,
            method: h.method,
            hostOS: h.host_os,
            dictionarySize: h.dictionary_size,
            unpackVersion: h.unpack_version
        )
    }
}

// MARK: - Native handle

private final class Handle {
    let raw: OpaquePointer

    init(url: URL, listOnly: Bool, password: String?) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ArchiveError.cannotOpen }
        var error: Int32 = 0
        let pointer: OpaquePointer? = url.path.withCString { path in
            if let password, !password.isEmpty {
                return password.withCString { cunrar_open(path, listOnly ? 1 : 0, $0, &error) }
            }
            return cunrar_open(path, listOnly ? 1 : 0, nil, &error)
        }
        guard let pointer else {
            // Encrypted headers + wrong password are reported as bad data / bad archive
            // by older archive formats.
            if password != nil, error == Int32(CUNRAR_BAD_DATA) { throw ArchiveError.wrongPassword }
            if error == Int32(CUNRAR_BAD_ARCHIVE) || error == Int32(CUNRAR_UNKNOWN_FORMAT),
               !RARArchive.hasRARSignature(url) {
                throw ArchiveError.notAnArchive
            }
            throw ArchiveError.from(code: error)
        }
        raw = pointer
    }

    func close() { cunrar_close(raw) }

    func error(for code: Int32, path: String? = nil, entry: ArchiveEntry? = nil) -> ArchiveError {
        if code == Int32(CUNRAR_MISSING_VOLUME) {
            let name = cunrar_missing_volume(raw).map { String(cString: $0) } ?? ""
            return .missingVolume(name: (name as NSString).lastPathComponent)
        }
        if code == Int32(CUNRAR_BAD_DATA), entry?.isEncrypted == true {
            // RAR 4 has no password check value: a wrong password shows up as a CRC error.
            return .wrongPassword
        }
        return .from(code: code, path: path)
    }
}
