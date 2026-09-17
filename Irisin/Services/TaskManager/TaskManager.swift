//
//  TaskManager.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/19.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import Combine
import Dog
import Foundation

nonisolated extension Notification.Name {
    /// The queue, its plan or its revision changed. Posted on the main actor.
    static let TaskQueueChanged = Notification.Name("wiki.qaq.TaskQueueChanged")
}

/// The queue: what the user asked for, in order, and the one plan that does
/// all of it. A change is proposed first, solved against the queue and shown
/// as a diff, then committed exactly as the user saw it, so a commit is an
/// assignment and never a second solve. Solving walks a copy of the package
/// index off the main actor. The revision tells a proposal made against an
/// older queue, or older packages, from a current one; nothing changes the
/// queue while an operation stages or runs.
final class TaskManager {
    static let shared = TaskManager()

    /// What the user asked for, one per identity, in the order asked.
    private(set) var actions: [ResolutionAction] = []
    /// Unneeded dependencies the user ticked to go with the queue.
    private(set) var cleanup: Set<String> = []
    /// What the queue does; nil while it is empty.
    private(set) var plan: ResolutionPlan?
    /// Why the plan could not follow the packages that changed under it.
    /// The old plan stays on screen and cannot be started.
    private(set) var blocked: String?
    /// Lines the queue page closes with: held-back updates, diagnostics.
    private(set) var notices: [String] = []
    private(set) var revision = 0

    /// The Settings switch: a plan may remove Essential and Protected
    /// packages, and the helper is told to let them go. A queued plan is
    /// solved again under the new answer: one that removes a system
    /// package does not outlive the switch.
    var allowSystemRemoval: Bool {
        get { allowSystemRemovalStore.wrappedValue }
        set {
            allowSystemRemovalStore.wrappedValue = newValue
            guard plan != nil else { return }
            refreshTask?.cancel()
            refreshTask = Task { await refresh(force: true) }
        }
    }

    private let allowSystemRemovalStore = PropertiesWrapper(key: "package.allowSystemRemoval", defaultValue: false)

    private var subscription: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    private init() {
        subscription = NotificationCenter.default.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.packagesChanged() }
    }

    /// A change, solved and not yet in the queue.
    struct Proposal {
        let actions: [ResolutionAction]
        let cleanup: Set<String>
        /// nil when the change empties the queue.
        let plan: ResolutionPlan?
        let notices: [String]
        let revision: Int
    }

    /// Solves the queue with `new` merged in: a request for a queued
    /// identity replaces the queued one, unless `keepingQueued` says the
    /// queue's own request wins. `cleanup` replaces the ticked set.
    func propose(
        _ new: [ResolutionAction],
        cleanup: Set<String>? = nil,
        keepingQueued: Bool = false,
        notices: [String] = []
    ) async -> Result<Proposal, ResolutionFailure> {
        var actions = actions
        for action in new {
            if let index = actions.firstIndex(where: { $0.identity == action.identity }) {
                if !keepingQueued {
                    actions[index] = action
                }
            } else {
                actions.append(action)
            }
        }
        return await proposal(actions: actions, cleanup: cleanup ?? self.cleanup, notices: notices)
    }

    /// Takes the proposal as the queue. False when the queue or the
    /// packages moved since it was made; the sheet proposes again.
    @discardableResult
    func commit(_ proposal: Proposal) -> Bool {
        guard proposal.revision == revision, !TaskProcessor.shared.inProcessingQueue else { return false }
        actions = proposal.actions
        cleanup = proposal.cleanup
        plan = proposal.plan
        notices = proposal.notices
        blocked = nil
        changed()
        // this starts what the plan needs and stops what it no longer does,
        // except a download Download Archive is waiting for
        DownloadCenter.shared.download(proposal.plan?.install ?? [])
        return true
    }

    /// The queue touches the package: asked for, ticked, or brought in.
    func isQueued(_ identity: String) -> Bool {
        actions.contains { $0.identity == identity }
            || cleanup.contains(identity)
            || plan.map { ($0.install + $0.remove).contains { $0.identity == identity } } ?? false
    }

    /// The version of the package the queue installs; nil when it installs
    /// none.
    func queuedVersion(of identity: String) -> String? {
        plan?.install.first { $0.identity == identity }?.latestVersion
    }

    /// Solves the queue without the package: its own request or tick, or
    /// the requests that bring it in. `cleanup` replaces the ticked set.
    func proposeWithdrawal(
        of identity: String,
        cleanup: Set<String>? = nil
    ) async -> Result<Proposal, ResolutionFailure> {
        let dropped = await requests(bringing: identity)
        return await proposal(
            actions: actions.filter { !dropped.contains($0.identity) },
            cleanup: (cleanup ?? self.cleanup).subtracting([identity]),
            notices: []
        )
    }

    /// The queued requests the package is in the plan for.
    private func requests(bringing identity: String) async -> Set<String> {
        let queued = Set(actions.map(\.identity))
        guard !queued.contains(identity), let plan else { return [identity] }
        if plan.install.contains(where: { $0.identity == identity }) {
            // up the dependency edges to the requests that need it
            var found: Set<String> = []
            var visited: Set<String> = []
            var pending = [identity]
            while let name = pending.popLast() {
                for dependent in plan.requiredBy[name] ?? [] where visited.insert(dependent).inserted {
                    if queued.contains(dependent) {
                        found.insert(dependent)
                    } else {
                        pending.append(dependent)
                    }
                }
            }
            return found
        }
        // ponytail: the plan does not say why a package leaves, so each
        // request is solved alone; a removal reason from the resolver
        // replaces this if long queues make it slow
        var found: Set<String> = []
        for action in actions {
            let alone = await proposal(actions: [action], cleanup: [], notices: [])
            if case let .success(alone) = alone,
               alone.plan?.remove.contains(where: { $0.identity == identity }) == true
            {
                found.insert(action.identity)
            }
        }
        return found
    }

    func clear() {
        guard !TaskProcessor.shared.inProcessingQueue else { return }
        actions = []
        cleanup = []
        plan = nil
        notices = []
        blocked = nil
        changed()
        DownloadCenter.shared.cancelAll()
    }

    /// Every installed package with a newer version, as install requests,
    /// and a line for each one an update of everything leaves behind.
    func updateAllActions() async -> Result<(actions: [ResolutionAction], notices: [String]), ResolutionFailure> {
        switch await solve(ResolutionRequest(updateAll: true)) {
        case let .success(plan):
            let installed = Set(plan.snapshot.installed.map(\.identity))
            return .success((
                plan.install.filter { installed.contains($0.identity) }.map { .install($0) },
                plan.heldBack.map {
                    String(localized: "\($0): kept at the current version by another package or a blocked update.")
                }
            ))
        case let .failure(failure):
            return .failure(failure)
        }
    }

    func blockUpdateEverything() {
        let identities = PackageCenter.default.index.obtainInstalledPackageList().map(\.identity)
        PackageCenter.default.blockedUpdateTable = Array(
            Set(PackageCenter.default.blockedUpdateTable).union(identities)
        ).sorted()
    }

    // MARK: - Operation

    /// An operation is staging or starting: an open proposal is stale.
    func operationBegan() {
        changed()
    }

    /// The queue is done once its plan ran; otherwise it stays, solved
    /// again against what the run left behind.
    func operationFinished(plan ran: ResolutionPlan, succeeded: Bool, dryRun: Bool) {
        if succeeded, !dryRun, plan?.id == ran.id {
            clear()
        } else {
            packagesChanged()
        }
    }

    /// Returns once the queue has been solved again against the packages
    /// as they last moved: what a failed run left is what Try Again stages.
    func settled() async {
        while let task = refreshTask {
            await task.value
            if task == refreshTask {
                return
            }
        }
    }

    // MARK: - Solving

    private func packagesChanged() {
        changed()
        guard plan != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    /// The packages moved: a plan that no longer matches them is solved
    /// again, and a local file the cache lost leaves the queue first. When
    /// that fails the old plan stays, blocked, with the reason.
    /// `force` solves again even when the packages did not move: the rules
    /// the plan was solved under did.
    private func refresh(force: Bool = false) async {
        guard !TaskProcessor.shared.inProcessingQueue, let plan else { return }
        let revision = revision
        if !force, await (try? Self.isCurrent(plan: plan, index: PackageCenter.default.index)) == true {
            return
        }
        guard !Task.isCancelled, revision == self.revision else { return }
        let kept = actions.filter { action in
            guard case let .install(package) = action, let file = package.localFileURL else { return true }
            return FileManager.default.fileExists(atPath: file.path)
        }
        let result = await proposal(actions: kept, cleanup: cleanup, notices: [])
        guard !Task.isCancelled, revision == self.revision else { return }
        switch result {
        case let .success(proposal):
            commit(proposal)
        case let .failure(failure):
            blocked = failure.message
            changed()
        }
    }

    /// Solves exactly these requests; a queue with no requests is empty.
    private func proposal(
        actions: [ResolutionAction],
        cleanup: Set<String>,
        notices: [String]
    ) async -> Result<Proposal, ResolutionFailure> {
        let revision = revision
        guard !actions.isEmpty else {
            return .success(Proposal(actions: [], cleanup: [], plan: nil, notices: [], revision: revision))
        }
        switch await solve(ResolutionRequest(actions: actions, autoremove: cleanup)) {
        case let .success(plan):
            return .success(Proposal(
                actions: actions,
                // a ticked package the plan does not remove is not kept to
                // take effect some later day
                cleanup: cleanup.intersection(plan.remove.map(\.identity)),
                plan: plan,
                notices: notices + Self.notices(of: plan),
                revision: revision
            ))
        case let .failure(failure):
            return .failure(failure)
        }
    }

    private func solve(_ request: ResolutionRequest) async -> Result<ResolutionPlan, ResolutionFailure> {
        guard !TaskProcessor.shared.inProcessingQueue else { return .failure(Self.busy) }
        let index = PackageCenter.default.index
        var request = request
        request.allowSystemRemoval = allowSystemRemoval
        do {
            let plan = try await Self.resolve(request: request, index: index)
            guard !TaskProcessor.shared.inProcessingQueue,
                  try await Self.isCurrent(plan: plan, index: PackageCenter.default.index),
                  // Revalidate actor-owned facts after the asynchronous status check.
                  !TaskProcessor.shared.inProcessingQueue,
                  plan.snapshot.blockedUpdates == Set(PackageCenter.default.blockedUpdateTable),
                  plan.snapshot.architecture == AptEnvironment.current.deviceArchitecture,
                  plan.snapshot.installableArchitectures == AptEnvironment.current.installableArchitectures
            else {
                throw Self.moved
            }
            return .success(plan)
        } catch {
            Dog.shared.join(self, String(describing: error), level: .error)
            return .failure(error as? ResolutionFailure ?? ResolutionFailure(.unknown))
        }
    }

    private static let busy = ResolutionFailure(
        message: String(localized: "Another operation is already running. Wait for it to finish, then try again.")
    )

    private static let moved = ResolutionFailure(
        message: String(localized: "Packages changed while checking dependencies. Try again.")
    )

    /// The plan's own lines; held-back updates come from the request.
    private static func notices(of plan: ResolutionPlan) -> [String] {
        var notices = plan.diagnostics.map(\.message)
        if plan.install.contains(where: { $0.identity == Bundle.main.bundleIdentifier }) {
            notices.insert(String(localized: "Irisin will restart when this finishes."), at: 0)
        }
        return notices
    }

    private func changed() {
        revision += 1
        NotificationCenter.default.post(name: .TaskQueueChanged, object: nil)
    }

    @concurrent
    private nonisolated static func resolve(
        request: ResolutionRequest,
        index: PackageIndex
    ) async throws -> ResolutionPlan {
        try PackageResolver.resolve(request: request, snapshot: index.resolutionSnapshot())
    }

    @concurrent
    nonisolated static func isCurrent(plan: ResolutionPlan, index: PackageIndex) async throws -> Bool {
        try index.isCurrent(plan.snapshot)
    }
}
