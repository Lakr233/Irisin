//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

/// invoke all metadata downloaded and build packages
/// - Parameters:
///   - original: parser, string
///   - fromRepo: repo reference
/// - Returns: container
func invokePackages(withContext original: String, fromRepo: URL? = nil) -> [String: Package] {
    var resultBuilder = [String: Package]()
    let device = AptEnvironment.current.deviceArchitecture
    let installable = AptEnvironment.current.installableArchitectures
    /// how well a flavour fits this bootstrap: built for it, adaptable to it, neither
    func fit(_ package: Package) -> Int {
        if package.supports(architecture: device) {
            return 2
        }
        if package.supports(anyOf: installable) {
            return 1
        }
        return 0
    }
    original
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n\n")
        .filter { $0.count > 0 }
        .compactMap { try? DebianControl.parse($0) }
        .forEach { metadata in
            guard let id = metadata["package"]?.lowercased(), // just lowercase
                  let ver = metadata["version"],
                  DebianVersion.isValid(ver)
            else {
                aptLog(
                    "AptMetaInvoker",
                    "dropping \(metadata["package"] ?? "an unnamed entry"): version \(metadata["version"] ?? "missing") is not one dpkg would accept",
                    level: .warning
                )
                return
            }
            // Every flavour is kept, so a package built for another bootstrap
            // still shows up and can say so. When one repository lists the
            // same package for several architectures, the flavour built for
            // this device wins, then one an adapter can rewrite for it.
            let incoming = Package(identity: id, payload: [ver: metadata], repoRef: fromRepo)
            guard let package = resultBuilder[id] else {
                resultBuilder[id] = incoming
                return
            }

            let existingFit = fit(package)
            let incomingFit = fit(incoming)
            if incomingFit < existingFit {
                return
            }
            if incomingFit > existingFit {
                resultBuilder[id] = incoming
                return
            }

            var newpayload = package.payload
            newpayload[ver] = metadata
            resultBuilder[id] = Package(
                identity: package.identity,
                payload: newpayload,
                repoRef: package.repoRef
            )
        }
    return resultBuilder
}
