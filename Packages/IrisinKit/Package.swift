// swift-tools-version: 5.9
import PackageDescription

/// Everything that is not UIKit lives here so it can be built and tested on a
/// Mac with plain `swift test`: the wire protocol, the job the root helper
/// carries out, and the app's link to the daemon.
///
/// irisind links IrisinProtocol only. irisin-install links
/// IrisinProtocol + IrisinInstaller, and through the installer our own
/// icli (`IcliKit`), on iOS and tvOS, and `IrisinPreparation`, which reads a
/// `.deb` with the libarchive icli already brings. The app links IrisinProtocol +
/// IrisinClient, and calls IrisinInstaller only in the simulator. Nothing here imports UIKit and nothing
/// third-party may reach the daemon: launchd caps it at 6 MB.
let package = Package(
    name: "IrisinKit",
    platforms: [.iOS(.v15), .tvOS(.v17), .visionOS("2.0"), .macOS(.v13)],
    products: [
        .library(name: "IrisinProtocol", targets: ["IrisinProtocol"]),
        .library(name: "IrisinInstaller", type: .static, targets: ["IrisinInstaller"]),
        .library(name: "IrisinClient", targets: ["IrisinClient"]),
        .library(name: "IrisinPreparation", targets: ["IrisinPreparation"]),
        .library(name: "IrisinVendor", targets: ["IrisinVendor"]),
    ],
    dependencies: [
        // Our own LaunchServices and SpringBoard code, linked into the helper
        // as a library: app registration and the graceful respring (PineBoard's
        // on tvOS, from 0.10.0). Not on the Mac.
        .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.10.0"),
        // icli's own libarchive, named here for `IrisinPreparation`: the same
        // package, so the helper gains no second copy, and the app already
        // links it through AptRepository.
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.1"),
        // The external clients' library, for the test that holds its wire to
        // IrisinProtocol's. Nothing that ships links it from here.
        .package(path: "../IrisinExternalClient"),
    ],
    targets: [
        // The SDK's XPC constants, read through C so nothing links the Swift
        // XPC overlay, a dylib iOS 15 does not have. See `IrisinXPC`.
        .systemLibrary(name: "CIrisinXPC", path: "Sources/CIrisinXPC"),

        // libSystem's spawn calls, which the AppleTVOS SDK marks unavailable,
        // declared again under labels naming the same symbols. See
        // `ProcessSpawn`.
        .systemLibrary(name: "CIrisinSpawn", path: "Sources/CIrisinSpawn"),

        // db(3) from `<db.h>`, which the Darwin module leaves out: the hash
        // files a bootstrap keeps its users in. See `BootstrapAccounts`.
        .systemLibrary(name: "CIrisinDB", path: "Sources/CIrisinDB"),

        // The wire vocabulary and the job description, compiled into every
        // side, and how the daemon and the helper find their install root
        // and start a process. Free of anything platform-specific beyond XPC
        // and posix_spawn.
        .target(name: "IrisinProtocol", dependencies: ["CIrisinXPC", "CIrisinSpawn"]),

        // A `.deb` into the prepared tree the helper installs from. The app
        // runs it as mobile on what it downloaded; the helper on a package an
        // external client submitted.
        .target(
            name: "IrisinPreparation",
            dependencies: [
                "IrisinProtocol",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
            ]
        ),

        // What `irisin-install` does as root: the dpkg transaction and the
        // maintenance actions, each with a fixed argv composed here.
        .target(
            name: "IrisinInstaller",
            dependencies: [
                "CIrisinDB",
                "IrisinProtocol",
                "IrisinPreparation",
                .product(name: "IcliKit", package: "icli", condition: .when(platforms: [.iOS, .tvOS])),
            ]
        ),

        // The app's side of the link: one request per call, the helper's
        // output as a stream of lines, and the rule for deciding that there is
        // no daemon to wait for. The installer is a dependency for the
        // simulator alone, where there is no daemon and `SimulatorDaemon`
        // runs the job in the app's own process; SwiftPM cannot say "only
        // there", and nothing names the module outside that condition.
        .target(name: "IrisinClient", dependencies: ["IrisinProtocol", "IrisinInstaller"]),

        // A paid repository's sign-in in the Keychain and the vendor's
        // endpoints, for the app and the command line alike: one spelling
        // of the Keychain names and one shape of every request, so the two
        // cannot drift. Foundation and Security only.
        .target(name: "IrisinVendor"),

        .testTarget(name: "IrisinProtocolTests", dependencies: ["IrisinProtocol"]),
        .testTarget(name: "IrisinVendorTests", dependencies: ["IrisinVendor"]),
        .testTarget(name: "IrisinInstallerTests", dependencies: ["CIrisinDB", "IrisinInstaller"]),
        .testTarget(name: "IrisinClientTests", dependencies: ["IrisinClient"]),
        .testTarget(
            name: "IrisinExternalContractTests",
            dependencies: ["IrisinProtocol", .product(name: "IrisinExternalClient", package: "IrisinExternalClient")]
        ),
    ]
)
