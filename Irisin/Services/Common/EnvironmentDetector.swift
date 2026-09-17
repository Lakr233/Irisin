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
    /// was built for before the first launch has a status file to read.
    static let packagedArchitectureKey = "IrisinCurrentArchitecture"

    /// The architecture the package says it is for, or nil for a build that
    /// was never packaged (Xcode, the simulator). A value naming no
    /// bootstrap is ignored the same way, so the vote below stays in charge
    /// of anything the plist cannot vouch for.
    static let packagedArchitecture: String? = {
        guard let value = Bundle.main.infoDictionary?[packagedArchitectureKey] as? String,
              BootstrapArchitecture(rawValue: value) != nil
        else { return nil }
        return value
    }()

    /// What the package was built for; when it was not packaged, what dpkg
    /// on this bootstrap thinks it is: the architecture most of its
    /// installed packages carry. Falls back to the layout (rootless ships
    /// arm64, roothide arm64e) when there is no status file to read either.
    static let architecture: String = {
        if let packagedArchitecture {
            return packagedArchitecture
        }
        var votes: [String: Int] = [:]
        if let status = try? String(contentsOfFile: JailbreakRoot.path("/Library/dpkg/status"), encoding: .utf8) {
            for line in status.split(separator: "\n") where line.hasPrefix("Architecture:") {
                let arch = line.dropFirst("Architecture:".count).trimmingCharacters(in: .whitespaces)
                if arch != "all" {
                    votes[arch, default: 0] += 1
                }
            }
        }
        if let winner = votes.max(by: { $0.value < $1.value })?.key {
            return winner
        }
        return JailbreakRoot.isRoothide ? "iphoneos-arm64e" : "iphoneos-arm64"
    }()
}
