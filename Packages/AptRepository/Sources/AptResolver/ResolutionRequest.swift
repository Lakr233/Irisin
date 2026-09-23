import AptRepository

public struct ResolutionRequest: Sendable {
    public var actions: [ResolutionAction]
    public var updateAll: Bool
    /// Installed packages to remove along with the plan once nothing needs
    /// them: names outside the plan's `unneeded`, or still needed by one
    /// left installed, are ignored.
    public var autoremove: Set<String>
    /// The user switched on removing system packages: an Essential or
    /// Protected package may leave the plan. `firmware` never does, it is
    /// the OS itself, and a protected package is still never offered for
    /// cleanup.
    public var allowSystemRemoval: Bool
    public init(
        actions: [ResolutionAction] = [],
        updateAll: Bool = false,
        autoremove: Set<String> = [],
        allowSystemRemoval: Bool = false
    ) {
        self.actions = actions
        self.updateAll = updateAll
        self.autoremove = autoremove
        self.allowSystemRemoval = allowSystemRemoval
    }

    /// The packages the request installs, in the order asked.
    var installs: [Package] {
        actions.compactMap { action in
            guard case let .install(package) = action else { return nil }
            return package
        }
    }
}
