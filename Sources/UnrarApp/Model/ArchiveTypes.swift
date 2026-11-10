import ArchiveKit
import Foundation
import UniformTypeIdentifiers

enum ArchiveTypes {
    /// The RAR type declared by WinRAR / RAR for macOS (imported in Info.plist).
    static let rar = UTType(importedAs: "com.rarlab.rar-archive", conformingTo: .archive)

    static var openable: [UTType] {
        var types: [UTType] = [rar, .zip, .gzip, .bz2, .archive]
        for ext in Archives.fileExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// Whether a dropped / opened file looks like something we can read.
    static func isSupported(_ url: URL) -> Bool {
        Archives.isSupported(url)
    }
}
