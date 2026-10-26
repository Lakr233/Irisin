// swift-tools-version: 6.0
import PackageDescription

/// Managing a device from a browser on the local network
/// (Documentation/WebManagement.md): the HTTP server on Network.framework,
/// the six-digit code and the key derived from it, the sealed envelope every
/// call travels in, and the page's files. Nothing outside the system, no
/// UIKit: the app and the Apple TV launcher answer the calls
/// (`WebResponder`), and everything here is tested on the Mac, the page's
/// own cipher against CryptoKit included.
let package = Package(
    name: "IrisinWeb",
    platforms: [.iOS(.v15), .tvOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "IrisinWeb", targets: ["IrisinWeb"]),
    ],
    targets: [
        .target(name: "IrisinWeb", resources: [.copy("Page")]),
        .testTarget(name: "IrisinWebTests", dependencies: ["IrisinWeb"]),
    ]
)
