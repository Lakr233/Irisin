//
//  LaunchpadSetup.swift
//  IrisinLaunchpad
//

import AptRepository
import Foundation

/// What the app's onboarding asks about and the launchpad, with nobody at
/// a screen to ask, does by itself once.
enum LaunchpadSetup {
    /// Set once the list has been added, so a repository the owner removed
    /// from the page stays removed.
    private static let recommendedAdded = Stored(key: "launchpad.recommendedRepositories", defaultValue: false)

    /// The recommended repositories for this bootstrap
    /// (`Resources/Environments`), on the first launch with none: the page
    /// has something to search the moment it opens.
    static func addRecommendedRepositories() async {
        guard !recommendedAdded.wrappedValue, await AppBootstrap.finished() else { return }
        recommendedAdded.wrappedValue = true
        guard RepositoryCenter.default.obtainRepositoryCount() == 0 else { return }
        for source in RecommendedRepositories.lines.compactMap(RepositorySource.init(line:)) {
            RepositoryCenter.default.registerRepository(source)
        }
    }
}
