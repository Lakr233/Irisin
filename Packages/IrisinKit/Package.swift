// swift-tools-version: 5.9
import PackageDescription

/// Everything that is not UIKit lives here so it can be built and tested on a
/// Mac with plain `swift test`: the wire protocol, the job the root helper
/// carries out, and the app's link to the daemon.
///
/// irisind links IrisinProtocol only. irisin-install links
/// IrisinProtocol + IrisinInstaller, and through the installer our own
/// icli (`IcliKit`), on iOS alone. The app links IrisinProtocol +
/// IrisinClient + IrisinAdapter, and calls IrisinInstaller only in
/// the simulator. Nothing here imports UIKit and nothing
/// third-party may reach the daemon: launchd caps it at 6 MB.
let package = Package(
    name: "IrisinKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IrisinProtocol", targets: ["IrisinProtocol"]),
        .library(name: "IrisinInstaller", type: .static, targets: ["IrisinInstaller"]),
        .library(name: "IrisinClient", targets: ["IrisinClient"]),
        .library(name: "IrisinAdapter", targets: ["IrisinAdapter"]),
    ],
    dependencies: [
        // Our own LaunchServices and SpringBoard code, linked into the helper
        // as a library: app registration and the graceful respring. iOS only.
        .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.6.8"),
        // Reads Mach-O for the adapter, as it does for Fila's inspector: where
        // a load command is, how long, what it says. It writes nothing; the
        // adapter's own code rewrites and signs. The adapter's alone.
        .package(url: "https://github.com/p-x9/MachOKit.git", from: "0.52.2"),
        // MachOKit's own dependency, named here only to hold it up: MachOKit
        // takes swift-fileio from 0.13 and swift-fileio-extra from 0.2.2, and
        // Xcode will pair swift-fileio 0.15 with extra 0.2.2, which does not
        // build against it. 0.3.0 does. The adapter lists the product because
        // Xcode drops the constraint of a dependency no target uses; MachOKit
        // links it regardless. Goes when MachOKit asks for 0.3.0 itself.
        .package(url: "https://github.com/p-x9/swift-fileio-extra.git", from: "0.3.0"),
    ],
    targets: [
        // The SDK's XPC constants, read through C so nothing links the Swift
        // XPC overlay, a dylib iOS 15 does not have. See `IrisinXPC`.
        .systemLibrary(name: "CIrisinXPC", path: "Sources/CIrisinXPC"),

        // The wire vocabulary and the job description, compiled into every
        // side. Free of anything platform-specific beyond XPC.
        .target(name: "IrisinProtocol", dependencies: ["CIrisinXPC"]),

        // What `irisin-install` does as root: the dpkg transaction and the
        // maintenance actions, each with a fixed argv composed here.
        .target(
            name: "IrisinInstaller",
            dependencies: [
                "IrisinProtocol",
                .product(name: "IcliKit", package: "icli", condition: .when(platforms: [.iOS])),
            ]
        ),

        // The app's side of the link: one request per call, the helper's
        // output as a stream of lines, and the rule for deciding that there is
        // no daemon to wait for. The installer is a dependency for the
        // simulator alone, where there is no daemon and `SimulatorDaemon`
        // runs the job in the app's own process; SwiftPM cannot say "only
        // there", and nothing names the module outside that condition.
        .target(name: "IrisinClient", dependencies: ["IrisinProtocol", "IrisinInstaller"]),

        // Rewrites a prepared package built for one bootstrap into one for
        // the bootstrap the app runs on, in the app, as `mobile`, before the
        // job is sent. Linked by the app only: the helper installs what it is
        // handed and never adapts anything.
        .target(
            name: "IrisinAdapter",
            dependencies: [
                "IrisinProtocol",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "FileIOBinary", package: "swift-fileio-extra"),
            ]
        ),

        .testTarget(name: "IrisinProtocolTests", dependencies: ["IrisinProtocol"]),
        .testTarget(name: "IrisinInstallerTests", dependencies: ["IrisinInstaller"]),
        .testTarget(name: "IrisinClientTests", dependencies: ["IrisinClient"]),
        .testTarget(
            name: "IrisinAdapterTests",
            dependencies: ["IrisinAdapter", .product(name: "MachOKit", package: "MachOKit")],
            exclude: ["Fixtures/build.sh", "Fixtures/fixture.c"],
            resources: [.copy("Fixtures/input"), .copy("Fixtures/expected")]
        ),
    ]
)
