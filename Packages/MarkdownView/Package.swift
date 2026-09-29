// swift-tools-version: 6.0

import PackageDescription

/// MarkdownView, vendored from Lakr233/MarkdownView 4.3.2 for UIKit alone,
/// without math or code highlighting. README.md says what changed.
let package = Package(
    name: "MarkdownView",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
        .library(name: "MarkdownParser", targets: ["MarkdownParser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/Litext", from: "2.2.2"),
        // Pinned: 1.7.0 built with Xcode 27 references `swift_initBorrow`,
        // which only iOS 27's libswiftCore has, and the app dies in dyld on
        // iOS 26 and older. Whoever moves this pin must have the developer
        // launch a packaged Release build on a device below iOS 27 first.
        // The same pin is in Irisin.xcodeproj; the two move together.
        .package(url: "https://github.com/apple/swift-collections", exact: "1.6.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.9.0"),
        .package(url: "https://github.com/nicklockwood/LRUCache", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                "Litext",
                "MarkdownParser",
                "LRUCache",
                .product(name: "DequeModule", package: "swift-collections"),
            ]
        ),
        .target(
            name: "MarkdownParser",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
    ]
)
