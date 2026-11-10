import XCTest
@testable import ArchiveKit

final class ArchiveKitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixture(_ name: String) throws -> URL {
        let url = try XCTUnwrap(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
        return url
    }

    private func read(_ relative: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: Listing

    func testListSimpleArchive() throws {
        let info = try RARArchive(url: fixture("simple.rar")).readInfo()
        let paths = Set(info.entries.map(\.path))
        XCTAssertEqual(paths, ["hello.txt", "docs", "docs/numbers.txt", "docs/nested",
                               "docs/nested/deep.txt", "Tài liệu", "Tài liệu/ghi chú.txt", "empty"])
        XCTAssertEqual(info.fileCount, 4)
        XCTAssertFalse(info.isSolid)
        XCTAssertFalse(info.hasEncryptedEntries)
        XCTAssertEqual(info.comment?.trimmingCharacters(in: .whitespacesAndNewlines), "Archive comment test")

        let hello = try XCTUnwrap(info.entries.first { $0.path == "hello.txt" })
        XCTAssertEqual(hello.uncompressedSize, 17)
        XCTAssertFalse(hello.isDirectory)
        XCTAssertEqual(hello.modificationDate, Date(timeIntervalSince1970: 1_714_564_800))
        XCTAssertTrue(info.entries.first { $0.path == "docs" }!.isDirectory)
        XCTAssertEqual(info.formatName, "RAR 5")
    }

    func testSolidFlag() throws {
        XCTAssertTrue(try RARArchive(url: fixture("solid.rar")).readInfo().isSolid)
    }

    func testNotAnArchive() throws {
        XCTAssertThrowsError(try RARArchive(url: fixture("not-an-archive.rar")).readInfo()) {
            XCTAssertEqual($0 as? ArchiveError, .notAnArchive)
        }
        XCTAssertFalse(RARArchive.hasRARSignature(try fixture("not-an-archive.rar")))
        XCTAssertTrue(RARArchive.hasRARSignature(try fixture("simple.rar")))
    }

    func testMissingFile() {
        XCTAssertThrowsError(try RARArchive(url: tempDir.appendingPathComponent("nope.rar")).readInfo()) {
            XCTAssertEqual($0 as? ArchiveError, .cannotOpen)
        }
    }

    // MARK: Extraction

    func testExtractAll() throws {
        let result = try RARArchive(url: fixture("simple.rar")).extract(to: tempDir)
        XCTAssertEqual(try read("hello.txt", in: tempDir), "Hello from Unrar\n")
        XCTAssertEqual(try read("docs/nested/deep.txt", in: tempDir), "deep file\n")
        XCTAssertEqual(try read("Tài liệu/ghi chú.txt", in: tempDir), "Xin chào thế giới\n")
        XCTAssertEqual(try read("docs/numbers.txt", in: tempDir).split(separator: "\n").count, 2000)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("empty").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(result.bytesWritten, 17 + 10 + 8893 + 23)

        // Modification dates are restored.
        let attributes = try FileManager.default.attributesOfItem(atPath: tempDir.appendingPathComponent("hello.txt").path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_714_564_800))
    }

    func testExtractSelection() throws {
        try RARArchive(url: fixture("solid.rar")).extract(paths: ["docs/nested"], to: tempDir)
        XCTAssertEqual(try read("docs/nested/deep.txt", in: tempDir), "deep file\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("hello.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("docs/numbers.txt").path))
    }

    func testExtractStrippingPrefix() throws {
        try RARArchive(url: fixture("simple.rar")).extract(
            paths: ["docs"], to: tempDir, options: ExtractionOptions(stripPrefix: "docs"))
        XCTAssertEqual(try read("nested/deep.txt", in: tempDir), "deep file\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("numbers.txt").path))
    }

    func testOverwritePolicies() throws {
        let archive = RARArchive(url: try fixture("simple.rar"))
        let hello = tempDir.appendingPathComponent("hello.txt")
        try "old".write(to: hello, atomically: true, encoding: .utf8)

        let skipped = try archive.extract(paths: ["hello.txt"], to: tempDir, options: ExtractionOptions(overwrite: .skip))
        XCTAssertEqual(skipped.skipped, ["hello.txt"])
        XCTAssertEqual(try read("hello.txt", in: tempDir), "old")

        try archive.extract(paths: ["hello.txt"], to: tempDir, options: ExtractionOptions(overwrite: .rename))
        XCTAssertEqual(try read("hello.txt", in: tempDir), "old")
        XCTAssertEqual(try read("hello (2).txt", in: tempDir), "Hello from Unrar\n")

        try archive.extract(paths: ["hello.txt"], to: tempDir, options: ExtractionOptions(overwrite: .overwrite))
        XCTAssertEqual(try read("hello.txt", in: tempDir), "Hello from Unrar\n")
    }

    func testProgressAndCancel() throws {
        let archive = RARArchive(url: try fixture("simple.rar"))
        var last: ExtractionProgress?
        try archive.extract(to: tempDir.appendingPathComponent("a")) { progress in
            last = progress
            return true
        }
        XCTAssertEqual(last?.filesProcessed, last?.totalFiles)
        XCTAssertEqual(last?.fractionCompleted ?? 0, 1, accuracy: 0.0001)

        XCTAssertThrowsError(try archive.extract(to: tempDir.appendingPathComponent("b")) { _ in false }) {
            XCTAssertEqual($0 as? ArchiveError, .cancelled)
        }
    }

    // MARK: Passwords

    func testEncryptedData() throws {
        let archive = RARArchive(url: try fixture("password.rar"))
        let info = try archive.readInfo() // names are readable without a password
        XCTAssertTrue(info.hasEncryptedEntries)
        XCTAssertTrue(info.entries.first { $0.path == "hello.txt" }!.isEncrypted)

        XCTAssertThrowsError(try archive.extract(to: tempDir)) {
            XCTAssertEqual($0 as? ArchiveError, .passwordRequired)
        }
        XCTAssertThrowsError(try archive.extract(to: tempDir, password: "wrong")) {
            XCTAssertEqual($0 as? ArchiveError, .wrongPassword)
        }
        try archive.extract(to: tempDir, password: "Secret123")
        XCTAssertEqual(try read("hello.txt", in: tempDir), "Hello from Unrar\n")
    }

    func testEncryptedHeaders() throws {
        let archive = RARArchive(url: try fixture("password-headers.rar"))
        XCTAssertThrowsError(try archive.readInfo()) {
            XCTAssertEqual($0 as? ArchiveError, .passwordRequired)
        }
        XCTAssertThrowsError(try archive.readInfo(password: "wrong")) {
            XCTAssertEqual($0 as? ArchiveError, .wrongPassword)
        }
        let info = try archive.readInfo(password: "Secret123")
        XCTAssertTrue(info.hasEncryptedHeaders)
        XCTAssertEqual(info.fileCount, 3)
        try archive.test(password: "Secret123")
        try archive.extract(to: tempDir, password: "Secret123")
        XCTAssertEqual(try read("docs/nested/deep.txt", in: tempDir), "deep file\n")
    }

    // MARK: Multi-volume

    func testMultiVolumeFromAnyPart() throws {
        let archive = RARArchive(url: try fixture("multi.part2.rar"))
        XCTAssertEqual(archive.url.lastPathComponent, "multi.part1.rar")
        let info = try archive.readInfo()
        XCTAssertTrue(info.isMultiVolume)
        XCTAssertEqual(info.entries.map(\.path), ["random.bin"])
        try archive.extract(to: tempDir)
        let data = try Data(contentsOf: tempDir.appendingPathComponent("random.bin"))
        XCTAssertEqual(data.count, 60_000)
    }

    func testMissingVolume() throws {
        let folder = tempDir.appendingPathComponent("vols")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["multi.part1.rar", "multi.part2.rar"] {
            try FileManager.default.copyItem(at: fixture(name), to: folder.appendingPathComponent(name))
        }
        let out = tempDir.appendingPathComponent("out")
        XCTAssertThrowsError(try RARArchive(url: folder.appendingPathComponent("multi.part1.rar")).extract(to: out)) {
            XCTAssertEqual($0 as? ArchiveError, .missingVolume(name: "multi.part3.rar"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("random.bin").path))
    }

    // MARK: Helpers

    func testPathSanitizer() {
        let options = ExtractionOptions()
        XCTAssertEqual(PathSanitizer.relativePath(for: "../../etc/passwd", options: options), "etc/passwd")
        XCTAssertEqual(PathSanitizer.relativePath(for: "/abs/file", options: options), "abs/file")
        XCTAssertEqual(PathSanitizer.relativePath(for: "C:\\Windows\\x.dll", options: options), "Windows/x.dll")
        XCTAssertEqual(PathSanitizer.relativePath(for: "a/./b/../c", options: options), "a/b/c")
        XCTAssertNil(PathSanitizer.relativePath(for: "..", options: options))
        XCTAssertEqual(PathSanitizer.relativePath(for: "a/b/c.txt", options: ExtractionOptions(flattenPaths: true)), "c.txt")
        XCTAssertNil(PathSanitizer.relativePath(for: "docs", options: ExtractionOptions(stripPrefix: "docs")))
        XCTAssertNil(PathSanitizer.relativePath(for: "other/x", options: ExtractionOptions(stripPrefix: "docs")))
    }

    func testSelectionMatching() {
        XCTAssertTrue(RARArchive.matches("a/b/c", ["a"]))
        XCTAssertTrue(RARArchive.matches("a/b/c", ["a/b/c"]))
        XCTAssertFalse(RARArchive.matches("ab/c", ["a"]))
        XCTAssertTrue(RARArchive.matches("x", nil))
    }

    func testTreeBuilding() throws {
        let entries = [
            ArchiveEntry(index: 0, path: "a/b/file.txt", uncompressedSize: 10, compressedSize: 5, isDirectory: false),
            ArchiveEntry(index: 1, path: "a/other.txt", uncompressedSize: 3, compressedSize: 3, isDirectory: false),
            ArchiveEntry(index: 2, path: "z.txt", uncompressedSize: 1, compressedSize: 1, isDirectory: false),
            ArchiveEntry(index: 3, path: "a", uncompressedSize: 0, compressedSize: 0, isDirectory: true),
        ]
        let root = ArchiveNode.build(from: entries)
        XCTAssertEqual(root.children.map(\.name), ["a", "z.txt"])
        let a = try XCTUnwrap(root.node(at: "a"))
        XCTAssertNotNil(a.entry)
        XCTAssertEqual(a.children.map(\.name), ["b", "other.txt"])
        XCTAssertEqual(a.uncompressedSize, 13)
        XCTAssertEqual(a.fileCount, 2)
        let b = try XCTUnwrap(root.node(at: "a/b"))
        XCTAssertNil(b.entry) // implied folder
        XCTAssertEqual(b.ancestry.map(\.name), ["a", "b"])
        XCTAssertEqual(root.uncompressedSize, 14)
        XCTAssertEqual(root.folderChildren?.map(\.name), ["a"])
    }

    func testFirstVolumeDetection() throws {
        let part = try fixture("multi.part3.rar")
        XCTAssertEqual(RARArchive.firstVolume(for: part).lastPathComponent, "multi.part1.rar")
        let simple = try fixture("simple.rar")
        XCTAssertEqual(RARArchive.firstVolume(for: simple), simple)
    }
}
