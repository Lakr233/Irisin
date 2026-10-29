// swift-tools-version: 5.9
import PackageDescription

/// The client side of irisind's external operations, for another package's
/// program that installs through Irisin (Apelin's session host first).
///
/// System libraries only, and no dependency on the rest of Irisin: it links
/// into a root process of someone else's, which takes nothing third-party.
/// A client vendors the two folders under `Sources/` with this repository's
/// LICENSE beside them, or depends on the package by path.
/// `Documentation/ExternalClients.md` is the contract it speaks.
let package = Package(
    name: "IrisinExternalClient",
    platforms: [.iOS(.v15), .tvOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IrisinExternalClient", targets: ["IrisinExternalClient"]),
    ],
    targets: [
        // The SDK's XPC constants, read through C so nothing links the Swift
        // XPC overlay, a dylib iOS 15 does not have.
        .systemLibrary(name: "CIrisinExternalXPC", path: "Sources/CIrisinExternalXPC"),
        .target(name: "IrisinExternalClient", dependencies: ["CIrisinExternalXPC"]),
    ]
)
