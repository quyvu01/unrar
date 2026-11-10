import XCTest
@testable import ArchiveKit

/// ZIP, 7z, TAR and single-file compressors (libarchive).
final class GenericArchiveTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenericArchiveTests-\(UUID().uuidString)")
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

    private let simplePaths: Set<String> = ["hello.txt", "docs", "docs/numbers.txt", "docs/nested",
                                            "docs/nested/deep.txt", "Tài liệu", "Tài liệu/ghi chú.txt", "empty"]

    // MARK: Listing and extraction

    func testSimpleArchivesInEveryFormat() throws {
        let formats = ["simple.zip": "ZIP", "simple.7z": "7Z", "simple.tar": "TAR", "simple.tar.gz": "TAR.GZ",
                       "simple.tar.bz2": "TAR.BZ2", "simple.tar.xz": "TAR.XZ"]
        for (name, format) in formats {
            let archive = Archives.reader(for: try fixture(name))
            XCTAssertTrue(archive is GenericArchive, name)
            let info = try archive.readInfo(password: nil)
            XCTAssertEqual(Set(info.entries.map(\.path)), simplePaths, name)
            XCTAssertEqual(info.fileCount, 4, name)
            XCTAssertEqual(info.formatName, format, name)
            XCTAssertFalse(info.hasEncryptedEntries, name)
            XCTAssertFalse(info.isRAR, name)
            XCTAssertGreaterThan(info.totalCompressedSize, 0, name)
            let hello = try XCTUnwrap(info.entries.first { $0.path == "hello.txt" }, name)
            XCTAssertEqual(hello.uncompressedSize, 17, name)
            XCTAssertEqual(hello.modificationDate, Date(timeIntervalSince1970: 1_714_564_800), name)

            let out = tempDir.appendingPathComponent(name)
            let result = try archive.extract(paths: nil, to: out, password: nil, options: ExtractionOptions(), progress: nil)
            XCTAssertEqual(result.bytesWritten, 17 + 10 + 8893 + 23, name)
            XCTAssertEqual(try read("hello.txt", in: out), "Hello from Unrar\n", name)
            XCTAssertEqual(try read("docs/nested/deep.txt", in: out), "deep file\n", name)
            XCTAssertEqual(try read("Tài liệu/ghi chú.txt", in: out), "Xin chào thế giới\n", name)
            XCTAssertEqual(try read("docs/numbers.txt", in: out).split(separator: "\n").count, 2000, name)
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("empty").path, isDirectory: &isDir), name)
            XCTAssertTrue(isDir.boolValue, name)
            let attributes = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("hello.txt").path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_714_564_800), name)

            try archive.test(password: nil, progress: nil)
        }
    }

    func testSingleCompressedFiles() throws {
        for name in ["numbers.txt.gz", "numbers.txt.bz2", "numbers.txt.xz"] {
            let archive = Archives.reader(for: try fixture(name))
            let info = try archive.readInfo(password: nil)
            XCTAssertEqual(info.entries.map(\.path), ["numbers.txt"], name)
            var last: ExtractionProgress?
            try archive.extract(paths: nil, to: tempDir.appendingPathComponent(name), password: nil,
                                options: ExtractionOptions()) { progress in
                last = progress
                return true
            }
            XCTAssertEqual(try read("\(name)/numbers.txt", in: tempDir).split(separator: "\n").count, 2000, name)
            XCTAssertEqual(last?.filesProcessed, 1, name)
        }
    }

    func testExtractSelectionAndPrefix() throws {
        let archive = Archives.reader(for: try fixture("simple.7z"))
        try archive.extract(paths: ["docs"], to: tempDir, password: nil,
                            options: ExtractionOptions(stripPrefix: "docs"), progress: nil)
        XCTAssertEqual(try read("nested/deep.txt", in: tempDir), "deep file\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("numbers.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("hello.txt").path))
    }

    func testOverwritePolicies() throws {
        let archive = Archives.reader(for: try fixture("simple.zip"))
        let hello = tempDir.appendingPathComponent("hello.txt")
        try "old".write(to: hello, atomically: true, encoding: .utf8)

        let skipped = try archive.extract(paths: ["hello.txt"], to: tempDir, password: nil,
                                          options: ExtractionOptions(overwrite: .skip), progress: nil)
        XCTAssertEqual(skipped.skipped, ["hello.txt"])
        XCTAssertEqual(try read("hello.txt", in: tempDir), "old")

        try archive.extract(paths: ["hello.txt"], to: tempDir, password: nil,
                            options: ExtractionOptions(overwrite: .rename), progress: nil)
        XCTAssertEqual(try read("hello (2).txt", in: tempDir), "Hello from Unrar\n")

        try archive.extract(paths: ["hello.txt"], to: tempDir, password: nil,
                            options: ExtractionOptions(overwrite: .overwrite), progress: nil)
        XCTAssertEqual(try read("hello.txt", in: tempDir), "Hello from Unrar\n")
    }

    func testProgressAndCancel() throws {
        let archive = Archives.reader(for: try fixture("simple.tar.gz"))
        var last: ExtractionProgress?
        try archive.extract(paths: nil, to: tempDir.appendingPathComponent("a"), password: nil,
                            options: ExtractionOptions()) { progress in
            last = progress
            return true
        }
        XCTAssertEqual(last?.filesProcessed, last?.totalFiles)
        XCTAssertEqual(last?.fractionCompleted ?? 0, 1, accuracy: 0.0001)

        XCTAssertThrowsError(try archive.extract(paths: nil, to: tempDir.appendingPathComponent("b"), password: nil,
                                                 options: ExtractionOptions()) { _ in false }) {
            XCTAssertEqual($0 as? ArchiveError, .cancelled)
        }
    }

    func testSplit7z() throws {
        // Opening any part reads the whole archive.
        let archive = GenericArchive(url: try fixture("split.7z.002"))
        XCTAssertEqual(archive.volumes.map(\.lastPathComponent), ["split.7z.001", "split.7z.002", "split.7z.003"])
        let info = try archive.readInfo()
        XCTAssertTrue(info.isMultiVolume)
        XCTAssertEqual(info.entries.map(\.path), ["random.bin"])
        try archive.extract(to: tempDir)
        let data = try Data(contentsOf: tempDir.appendingPathComponent("random.bin"))
        XCTAssertEqual(data.count, 300_000)
    }

    // MARK: Passwords

    func testZipPasswords() throws {
        for name in ["password.zip", "password-aes.zip"] {
            let archive = Archives.reader(for: try fixture(name))
            let info = try archive.readInfo(password: nil)
            XCTAssertTrue(info.hasEncryptedEntries, name)
            XCTAssertThrowsError(try archive.extract(paths: nil, to: tempDir, password: nil,
                                                     options: ExtractionOptions(), progress: nil), name) {
                XCTAssertEqual($0 as? ArchiveError, .passwordRequired, name)
            }
            XCTAssertThrowsError(try archive.extract(paths: nil, to: tempDir, password: "wrong",
                                                     options: ExtractionOptions(), progress: nil), name) {
                XCTAssertEqual($0 as? ArchiveError, .wrongPassword, name)
            }
            let out = tempDir.appendingPathComponent(name)
            try archive.extract(paths: nil, to: out, password: "Secret123", options: ExtractionOptions(), progress: nil)
            XCTAssertEqual(try read("hello.txt", in: out), "Hello from Unrar\n", name)
            XCTAssertEqual(try read("docs/numbers.txt", in: out).split(separator: "\n").count, 2000, name)
        }
    }

    func testEncrypted7zIsReportedAsUnsupported() throws {
        let archive = Archives.reader(for: try fixture("password.7z"))
        XCTAssertTrue(try archive.readInfo(password: nil).hasEncryptedEntries)
        XCTAssertThrowsError(try archive.extract(paths: nil, to: tempDir, password: "Secret123",
                                                 options: ExtractionOptions(), progress: nil)) {
            XCTAssertEqual($0 as? ArchiveError, .unsupportedEncryption)
        }
        XCTAssertThrowsError(try Archives.reader(for: try fixture("password-headers.7z")).readInfo(password: nil)) {
            XCTAssertEqual($0 as? ArchiveError, .unsupportedEncryption)
        }
    }

    // MARK: Safety

    func testMaliciousPathsAndLinksStayInsideDestination() throws {
        let out = tempDir.appendingPathComponent("out")
        try Archives.reader(for: try fixture("evil.tar"))
            .extract(paths: nil, to: out, password: nil, options: ExtractionOptions(), progress: nil)
        let fm = FileManager.default
        // "../../escape.txt" and "/abs.txt" land inside the destination.
        XCTAssertEqual(try read("escape.txt", in: out), "pwned\n")
        XCTAssertEqual(try read("abs.txt", in: out), "pwned\n")
        XCTAssertFalse(fm.fileExists(atPath: tempDir.appendingPathComponent("escape.txt").path))
        // Links pointing outside are dropped, safe ones are kept.
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("safe/abs-link").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("safe/rel-escape").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("safe/ok-link").path), "x.txt")
        XCTAssertEqual(try read("safe/hard", in: out), "pwned\n")
    }

    func testSymlinkSafety() {
        XCTAssertTrue(GenericArchive.isSafeSymlink("x.txt", at: "a/link"))
        XCTAssertTrue(GenericArchive.isSafeSymlink("../b/x", at: "a/link"))
        XCTAssertFalse(GenericArchive.isSafeSymlink("../../x", at: "a/link"))
        XCTAssertFalse(GenericArchive.isSafeSymlink("/etc/passwd", at: "link"))
    }

    // MARK: Detection

    func testDetection() throws {
        XCTAssertTrue(Archives.reader(for: try fixture("simple.rar")) is RARArchive)
        XCTAssertTrue(Archives.reader(for: try fixture("simple.zip")) is GenericArchive)
        for name in ["simple.zip", "simple.7z", "simple.tar", "simple.tar.gz", "numbers.txt.xz", "split.7z.003"] {
            XCTAssertTrue(Archives.isSupported(try fixture(name)), name)
        }
        XCTAssertFalse(Archives.isSupported(URL(fileURLWithPath: "/tmp/photo.jpg")))

        let plain = tempDir.appendingPathComponent("notes.txt")
        try "just text".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GenericArchive(url: plain).readInfo()) {
            XCTAssertEqual($0 as? ArchiveError, .notAnArchive)
        }
    }

    func testStem() {
        XCTAssertEqual(Archives.stem(of: URL(fileURLWithPath: "/x/Photos.tar.gz")), "Photos")
        XCTAssertEqual(Archives.stem(of: URL(fileURLWithPath: "/x/Backup.7z.001")), "Backup")
        XCTAssertEqual(Archives.stem(of: URL(fileURLWithPath: "/x/Movie.part1.rar")), "Movie")
        XCTAssertEqual(Archives.stem(of: URL(fileURLWithPath: "/x/notes.txt.gz")), "notes.txt")
        XCTAssertEqual(Archives.stem(of: URL(fileURLWithPath: "/x/v1.2.zip")), "v1.2")
    }
}
