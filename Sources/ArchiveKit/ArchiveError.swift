import Foundation
import CUnrar

public enum ArchiveError: Error, Equatable, Sendable {
    /// The archive (or an entry) is encrypted and no password was given.
    case passwordRequired
    /// The password is wrong.
    case wrongPassword
    /// CRC / checksum failure. For encrypted entries in RAR 4 archives this
    /// usually means a wrong password.
    case corruptData(path: String?)
    case brokenArchive
    case notAnArchive
    case cannotOpen
    case cannotCreate(path: String)
    case readFailed
    case writeFailed(path: String?)
    case missingVolume(name: String)
    case cancelled
    case outOfMemory
    case unknown(code: Int32)

    static func from(code: Int32, path: String? = nil) -> ArchiveError {
        switch Int(code) {
        case Int(CUNRAR_MISSING_PASSWORD): return .passwordRequired
        case Int(CUNRAR_BAD_PASSWORD): return .wrongPassword
        case Int(CUNRAR_BAD_DATA): return .corruptData(path: path)
        case Int(CUNRAR_BAD_ARCHIVE): return .brokenArchive
        case Int(CUNRAR_UNKNOWN_FORMAT): return .notAnArchive
        case Int(CUNRAR_EOPEN): return .cannotOpen
        case Int(CUNRAR_ECREATE): return .cannotCreate(path: path ?? "")
        case Int(CUNRAR_EREAD): return .readFailed
        case Int(CUNRAR_EWRITE): return .writeFailed(path: path)
        case Int(CUNRAR_NO_MEMORY): return .outOfMemory
        case Int(CUNRAR_CANCELLED): return .cancelled
        default: return .unknown(code: code)
        }
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return L("This archive is protected by a password.")
        case .wrongPassword:
            return L("The password is incorrect.")
        case .corruptData(let path):
            if let path {
                return String(format: L("Checksum error in “%@”. The file is damaged or the password is incorrect."), path)
            }
            return L("Checksum error. The archive is damaged or the password is incorrect.")
        case .brokenArchive:
            return L("The archive is damaged.")
        case .notAnArchive:
            return L("This file is not a RAR archive or uses an unsupported format.")
        case .cannotOpen:
            return L("The archive could not be opened.")
        case .cannotCreate(let path):
            return String(format: L("Could not create “%@”."), path)
        case .readFailed:
            return L("Could not read the archive.")
        case .writeFailed(let path):
            if let path { return String(format: L("Could not write “%@”. Check free disk space and permissions."), path) }
            return L("Could not write to disk. Check free disk space and permissions.")
        case .missingVolume(let name):
            return String(format: L("The next volume “%@” is missing. Put all parts of the archive in the same folder."), name)
        case .cancelled:
            return L("The operation was cancelled.")
        case .outOfMemory:
            return L("Not enough memory.")
        case .unknown(let code):
            return String(format: L("Unknown error (%ld)."), Int(code))
        }
    }
}
