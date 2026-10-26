import AptResolver

extension ResolutionPlan {
    /// Whether the helper can place every file of the plan before any of
    /// its scripts runs: nothing removed, nothing already installed, and
    /// nothing configured but what the plan installs or an earlier run
    /// left unpacked, as a Bootstrap Install that failed does.
    nonisolated var allowsBootstrapInstall: Bool {
        let installing = Set(install.map(\.identity))
        let installed = Set(snapshot.installed.map(\.identity))
        let unconfigured = Set(snapshot.installed.filter {
            $0.latestMetadata?["status"]?.hasSuffix(" installed") == false
        }.map(\.identity))
        let configuring = Set(stages.flatMap { stage -> [String] in
            if case let .configure(names) = stage {
                return names
            }
            return []
        })
        return !installing.isEmpty && remove.isEmpty && !recoveryMode
            && installing.isDisjoint(with: installed) && configuring.isSubset(of: installing.union(unconfigured))
    }
}
