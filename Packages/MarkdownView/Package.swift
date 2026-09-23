// swift-tools-version: 6.0

import PackageDescription

// MarkdownView, vendored from Lakr233/MarkdownView 4.3.2 for UIKit alone,
// without math or code highlighting. README.md says what changed.
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
        .package(url: "https://github.com/apple/swift-collections", from: "1.7.0"),
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
