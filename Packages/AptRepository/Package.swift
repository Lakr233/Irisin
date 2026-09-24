// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AptRepository",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AptRepository", targets: ["AptRepository"]),
        .library(name: "AptResolver", targets: ["AptResolver"]),
        .executable(name: "ResolverProbe", targets: ["ResolverProbe"]),
        .executable(name: "NativeInstallerProbe", targets: ["NativeInstallerProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libsolv.xcframework", from: "0.1.1"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.0"),
        .package(path: "../IrisinKit"),
        // Prebuilt WCDB (sqlite + sqlcipher + the C++ core in one dynamic
        // framework). The catalogue lives in its database; see Storage/.
        .package(url: "https://github.com/Lakr233/wcdb.xcframework", from: "2.1.16"),
        // the packages a list draws, held by the center; MarkdownView
        // already links it into the app
        .package(url: "https://github.com/nicklockwood/LRUCache", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AptRepository",
            dependencies: [
                // Every compression filter a repository index or a .deb can
                // carry, including zstd, plus the ar and tar containers, in
                // one static binary. It comes through the package rather than
                // a binary target of our own because icli, linked into the
                // helper, brings the same package into the graph, and two
                // targets named `libarchive` do not resolve.
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                .product(name: "IrisinProtocol", package: "IrisinKit"),
                .product(name: "WCDBSwift", package: "wcdb.xcframework"),
                "LRUCache",
            ]
        ),
        .target(
            name: "AptResolver",
            dependencies: [
                "AptRepository",
                .product(name: "LibSolv", package: "libsolv.xcframework"),
                .product(name: "IrisinProtocol", package: "IrisinKit"),
            ]
        ),
        // the catalogue benchmark solves with the shipped adapters' preview,
        // as the app does
        .executableTarget(
            name: "ResolverProbe",
            dependencies: ["AptResolver", .product(name: "IrisinAdapter", package: "IrisinKit")],
            path: "Tools/ResolverProbe"
        ),
        .executableTarget(
            name: "NativeInstallerProbe",
            dependencies: [
                "AptRepository",
                .product(name: "IrisinInstaller", package: "IrisinKit"),
            ],
            path: "Tools/NativeInstallerProbe"
        ),
        .testTarget(name: "AptResolverTests", dependencies: ["AptResolver"]),
        .testTarget(
            name: "AptRepositoryTests",
            // the adapter only for `AdapterConformanceTests`, which needs both
            // halves: a package prepared here, then adapted there; the
            // resolver for `ResolutionPoolDatabaseTests`, a pool read from a
            // database and the database written under it
            dependencies: [
                "AptRepository",
                "AptResolver",
                .product(name: "IrisinAdapter", package: "IrisinKit"),
            ],
            // a Debian machine's dpkg status file and a version list sorted
            // by apt itself, for the parser and the comparison
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
