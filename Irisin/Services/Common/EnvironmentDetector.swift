//
//  EnvironmentDetector.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import IrisinAdapter

/// Which dpkg architecture the packages on this bootstrap carry, so
/// AptRepository asks repositories for the flavour that will actually
/// install. There is no override: a package of any other architecture does
/// not install as built, so offering one would only produce a list of
/// packages that fail; the ones an adapter rewrites are listed through
/// `PackageAdapters.installable`. Read from AptRepository's threads, so
/// nonisolated.
nonisolated enum EnvironmentDetector {
    /// The Info.plist key `package-deb.sh` fills in per flavor: the app is
    /// one binary packaged twice, and the package knows which bootstrap it
    /// was built for before its first launch.
    static let packagedArchitectureKey = "IrisinCurrentArchitecture"

    /// The architecture the package says it is for, or nil for a build that
    /// was never packaged (Xcode, the simulator). An unrecognized string
    /// stays a mismatch; it must not silently become the detected value.
    static let packagedArchitecture = Bundle.main.infoDictionary?[packagedArchitectureKey] as? String

    /// A packaged build never switches architecture to fit its environment.
    /// Only an unpackaged development build uses the detected architecture.
    static let architecture = packagedArchitecture ?? detectedArchitecture

    /// Independent of the app's plist and installed package mix: the layout
    /// reported by the bootstrap's runtime library determines its package
    /// architecture, which is distinct from the CPU's Mach-O architecture.
    static let detectedArchitecture = JailbreakRoot.isRoothide
        ? BootstrapArchitecture.roothide.rawValue
        : BootstrapArchitecture.rootless.rawValue

    static let incompatibilityMessage = incompatibilityMessage(
        packagedArchitecture: packagedArchitecture,
        detectedArchitecture: detectedArchitecture
    )

    /// A patcher may rewrite the Debian control file, but the app still
    /// requires the bootstrap it was packaged for. Setup stops here.
    static func incompatibilityMessage(packagedArchitecture: String?, detectedArchitecture: String) -> String? {
        guard let packagedArchitecture, packagedArchitecture != detectedArchitecture else { return nil }
        return String(localized: "This copy of Irisin is built for \(packagedArchitecture), but your bootstrap uses \(detectedArchitecture). Install the matching official Irisin package. Do not install Irisin using a patcher.")
    }
}
