import ArchiveKit
import Foundation

// Small command line front end (RAR, ZIP, 7z, TAR …) for ArchiveKit, mostly used for testing.
//
//   rarkit list    <archive> [-p password]
//   rarkit extract <archive> <destination> [-p password] [--skip|--overwrite]
//   rarkit test    <archive> [-p password]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var password: String?
var policy = OverwritePolicy.rename
if let i = arguments.firstIndex(of: "-p"), i + 1 < arguments.count {
    password = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
}
if let i = arguments.firstIndex(of: "--skip") { policy = .skip; arguments.remove(at: i) }
if let i = arguments.firstIndex(of: "--overwrite") { policy = .overwrite; arguments.remove(at: i) }

guard arguments.count >= 2 else {
    fail("usage: rarkit list|extract|test <archive> [destination] [-p password] [--skip|--overwrite]")
}

let archive = Archives.reader(for: URL(fileURLWithPath: arguments[1]))
let formatter = ByteCountFormatter()

do {
    switch arguments[0] {
    case "list":
        let info = try archive.readInfo(password: password)
        print("Archive: \(info.url.lastPathComponent)  format=\(info.formatName)  solid=\(info.isSolid) volume=\(info.isMultiVolume) encryptedHeaders=\(info.hasEncryptedHeaders)")
        if let comment = info.comment { print("Comment: \(comment)") }
        for entry in info.entries {
            let kind = entry.isDirectory ? "D" : (entry.isLink ? "L" : "F")
            let lock = entry.isEncrypted ? "*" : " "
            print("\(kind)\(lock) \(String(entry.uncompressedSize).leftPad(12)) \(String(entry.compressedSize).leftPad(12))  \(entry.path)")
        }
        print("\(info.fileCount) files, \(formatter.string(fromByteCount: Int64(info.totalUncompressedSize)))")

    case "extract":
        guard arguments.count >= 3 else { fail("missing destination") }
        let destination = URL(fileURLWithPath: arguments[2])
        let selection = arguments.count > 3 ? Set(arguments[3...]) : nil
        var lastPercent = -1
        let result = try archive.extract(paths: selection, to: destination, password: password,
                                         options: ExtractionOptions(overwrite: policy), progress: { progress in
            let percent = Int(progress.fractionCompleted * 100)
            if percent != lastPercent {
                lastPercent = percent
                FileHandle.standardError.write("\r\(percent)% \(progress.currentPath ?? "")\u{1B}[K".data(using: .utf8)!)
            }
            return true
        })
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        print("Extracted \(result.extracted.count) items (\(formatter.string(fromByteCount: Int64(result.bytesWritten)))), skipped \(result.skipped.count)")

    case "test":
        try archive.test(password: password, progress: nil)
        print("OK")

    default:
        fail("unknown command \(arguments[0])")
    }
} catch let error as ArchiveError {
    fail("error: \(error.localizedDescription) [\(error)]")
} catch {
    fail("error: \(error.localizedDescription)")
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
