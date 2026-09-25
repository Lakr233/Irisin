// swift-tools-version: 6.0

import PackageDescription

/// Runestone, vendored: simonbs/Runestone's text view, the Tree-sitter runtime,
/// and only the grammars Irisin highlights (bash and JSON). README.md says
/// where each part came from and what changed.
let package = Package(
    name: "Runestone",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "Runestone", targets: ["Runestone"]),
        .library(name: "RunestoneLanguageSupport", targets: ["RunestoneLanguageSupport"]),
        .library(name: "RunestoneThemeSupport", targets: ["RunestoneThemeSupport"]),
    ],
    targets: [
        // lib.c includes every other runtime source; compiling them again
        // would define each symbol twice.
        .target(
            name: "TreeSitter",
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterBash",
            dependencies: ["TreeSitter"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterJSON",
            dependencies: ["TreeSitter"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        // Upstream's own sources, written before strict concurrency.
        .target(
            name: "Runestone",
            dependencies: ["TreeSitter"],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
                .process("TextView/Appearance/Theme.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("ConciseMagicFile"),
            ]
        ),
        .target(
            name: "RunestoneLanguageSupport",
            dependencies: ["Runestone", "TreeSitterBash", "TreeSitterJSON"]
        ),
        .target(
            name: "RunestoneThemeSupport",
            dependencies: ["Runestone"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
