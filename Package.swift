// swift-tools-version:5.9
import PackageDescription

// UnRAR translation units, mirroring OBJECTS + LIB_OBJ of unrar/makefile
// (`make lib`). Other .cpp files in that folder are #included by these.
let unrarSources = [
    "rar.cpp", "strlist.cpp", "strfn.cpp", "pathfn.cpp", "smallfn.cpp", "global.cpp",
    "file.cpp", "filefn.cpp", "filcreat.cpp", "archive.cpp", "arcread.cpp", "unicode.cpp",
    "system.cpp", "crypt.cpp", "crc.cpp", "rawread.cpp", "encname.cpp", "resource.cpp",
    "match.cpp", "timefn.cpp", "rdwrfn.cpp", "consio.cpp", "options.cpp", "errhnd.cpp",
    "rarvm.cpp", "secpassword.cpp", "rijndael.cpp", "getbits.cpp", "sha1.cpp", "sha256.cpp",
    "blake2s.cpp", "hash.cpp", "extinfo.cpp", "extract.cpp", "volume.cpp", "list.cpp",
    "find.cpp", "unpack.cpp", "headers.cpp", "threadpool.cpp", "rs16.cpp", "cmddata.cpp",
    "ui.cpp", "filestr.cpp", "scantree.cpp", "dll.cpp", "qopen.cpp",
].map { "unrar/\($0)" }

var products: [Product] = [
    .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    .executable(name: "rarkit", targets: ["rarkit"]),
]

var targets: [Target] = [
    .target(
        name: "CUnrar",
        path: "Sources/CUnrar",
        sources: ["shim.cpp"] + unrarSources,
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("unrar"),
            .define("RARDLL"),
            .define("RAR_SMP"),
            .define("_FILE_OFFSET_BITS", to: "64"),
            .define("_LARGEFILE_SOURCE"),
        ],
        linkerSettings: [
            .linkedLibrary("pthread", .when(platforms: [.linux])),
        ]
    ),
    .target(name: "ArchiveKit", dependencies: ["CUnrar"]),
    .executableTarget(name: "rarkit", dependencies: ["ArchiveKit"]),
    .testTarget(
        name: "ArchiveKitTests",
        dependencies: ["ArchiveKit"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "Unrar", targets: ["UnrarApp"]))
targets.append(
    .executableTarget(
        name: "UnrarApp",
        dependencies: ["ArchiveKit"],
        path: "Sources/UnrarApp",
        // Info.plist and the *.lproj folders are copied into Unrar.app by
        // scripts/build-app.sh so that Bundle.main picks them up.
        exclude: ["Info.plist", "Resources"]
    )
)
#endif

let package = Package(
    name: "Unrar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    cxxLanguageStandard: .cxx14
)
