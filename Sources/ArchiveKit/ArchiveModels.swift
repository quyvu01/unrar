import Foundation

/// A single file or folder stored in an archive.
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    /// Position of the entry in the archive (0-based, in header order).
    public let index: Int
    /// Path inside the archive, `/` separated, without a leading slash.
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let isDirectory: Bool
    public let isEncrypted: Bool
    public let isSolid: Bool
    /// Symbolic link, hard link or junction.
    public let isLink: Bool
    public let modificationDate: Date?
    public let crc32: UInt32
    /// RAR compression method (0x30 = store ... 0x35 = best).
    public let method: UInt32
    public let hostOS: UInt32
    public let dictionarySize: UInt64
    /// Version of the algorithm needed to unpack (e.g. 29 = RAR 3/4, 50 = RAR 5, 70 = RAR 7).
    public let unpackVersion: UInt32

    public var id: Int { index }

    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Ratio of compressed to uncompressed size (0...1+), nil for empty files.
    public var compressionRatio: Double? {
        guard uncompressedSize > 0, !isDirectory else { return nil }
        return Double(compressedSize) / Double(uncompressedSize)
    }

    public var methodName: String {
        switch method {
        case 0x30: return "Store"
        case 0x31: return "Fastest"
        case 0x32: return "Fast"
        case 0x33: return "Normal"
        case 0x34: return "Good"
        case 0x35: return "Best"
        default: return String(format: "0x%02X", method)
        }
    }

    public init(index: Int, path: String, uncompressedSize: UInt64, compressedSize: UInt64,
                isDirectory: Bool, isEncrypted: Bool = false, isSolid: Bool = false,
                isLink: Bool = false, modificationDate: Date? = nil, crc32: UInt32 = 0,
                method: UInt32 = 0, hostOS: UInt32 = 0, dictionarySize: UInt64 = 0,
                unpackVersion: UInt32 = 0) {
        self.index = index
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.isSolid = isSolid
        self.isLink = isLink
        self.modificationDate = modificationDate
        self.crc32 = crc32
        self.method = method
        self.hostOS = hostOS
        self.dictionarySize = dictionarySize
        self.unpackVersion = unpackVersion
    }
}

/// Information about an opened archive.
public struct ArchiveInfo: Sendable {
    public let url: URL
    public let entries: [ArchiveEntry]
    public let isSolid: Bool
    public let isMultiVolume: Bool
    public let hasEncryptedHeaders: Bool
    public let isLocked: Bool
    public let hasRecoveryRecord: Bool
    public let comment: String?

    public var hasEncryptedEntries: Bool { hasEncryptedHeaders || entries.contains { $0.isEncrypted } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var totalUncompressedSize: UInt64 { entries.reduce(0) { $0 + $1.uncompressedSize } }
    public var totalCompressedSize: UInt64 { entries.reduce(0) { $0 + $1.compressedSize } }

    /// Human readable format, derived from the highest unpack version used.
    public var formatName: String {
        let version = entries.filter { !$0.isDirectory }.map(\.unpackVersion).max() ?? 0
        switch version {
        case 70...: return "RAR 7"
        case 50...: return "RAR 5"
        case 29...: return "RAR 4"
        case 1...: return "RAR 2"
        default: return "RAR"
        }
    }
}

/// What to do when a file being extracted already exists.
public enum OverwritePolicy: String, CaseIterable, Sendable, Codable {
    case overwrite
    case skip
    /// Keep both: the new file is saved as "name (2).ext".
    case rename
}

public struct ExtractionOptions: Sendable {
    public var overwrite: OverwritePolicy
    /// Extract without the folder structure stored in the archive.
    public var flattenPaths: Bool
    /// Strip this prefix from entry paths (used when extracting a sub folder).
    public var stripPrefix: String?

    public init(overwrite: OverwritePolicy = .rename, flattenPaths: Bool = false, stripPrefix: String? = nil) {
        self.overwrite = overwrite
        self.flattenPaths = flattenPaths
        self.stripPrefix = stripPrefix
    }
}

public struct ExtractionProgress: Sendable {
    public var bytesProcessed: UInt64
    public var totalBytes: UInt64
    public var filesProcessed: Int
    public var totalFiles: Int
    public var currentPath: String?

    public init(bytesProcessed: UInt64 = 0, totalBytes: UInt64 = 0, filesProcessed: Int = 0,
                totalFiles: Int = 0, currentPath: String? = nil) {
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return totalFiles > 0 ? Double(filesProcessed) / Double(totalFiles) : 0 }
        return min(1, Double(bytesProcessed) / Double(totalBytes))
    }
}

public struct ExtractionResult: Sendable {
    /// Files and folders written to disk.
    public var extracted: [URL] = []
    /// Entries skipped because the destination already existed.
    public var skipped: [String] = []
    public var bytesWritten: UInt64 = 0

    public init() {}
}
