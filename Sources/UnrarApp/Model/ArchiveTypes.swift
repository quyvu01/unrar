import ArchiveKit
import Foundation
import UniformTypeIdentifiers

enum ArchiveTypes {
    /// The RAR type declared by WinRAR / RAR for macOS (imported in Info.plist).
    static let rar = UTType(importedAs: "com.rarlab.rar-archive", conformingTo: .archive)

    static var openable: [UTType] {
        var types: [UTType] = [rar]
        for ext in RARArchive.fileExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// Whether a dropped / opened file looks like something we can read.
    static func isSupported(_ url: URL) -> Bool {
        if RARArchive.fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        // Old style volumes: .r00, .r01, ...
        if url.pathExtension.range(of: #"^r\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return RARArchive.hasRARSignature(url)
    }
}
