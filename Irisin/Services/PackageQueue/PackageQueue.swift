//
//  PackageQueue.swift
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
import IrisinAdapter
import UIKit

nonisolated extension Notification.Name {
    /// The queue, its plan or its revision changed. Posted on the main actor.
    static let PackageQueueChanged = Notification.Name("wiki.qaq.PackageQueueChanged")
}

/// The queue: what the user asked for, in order, and the one plan that does
/// all of it. A change is proposed first, solved against the queue and shown
/// as a diff, then committed exactly as the user saw it, so a commit is an
/// assignment and never a second solve. Solving walks a copy of the package
/// index off the main actor. The revision tells a proposal made against an
/// older queue, or older packages, from a current one; nothing changes the
/// queue while an operation stages or runs.
///
/// What a solve does for every request alike, reading the catalogue and
/// matching every relation in it (`ResolutionPool`), is done ahead, off the
/// main actor, once the packages stop moving, so a tap solves only its own
/// jobs. A pool read from anything but the packages as they are is never
/// solved with: the resolver checks it against the snapshot of each solve.
///
/// The one exception is a refresh, which writes one repository after
/// another: until the last is written, a solve keeps the catalogue last
/// read, the queue is not solved again for each write, and an open sheet
/// is not either. The plan says which catalogue it was solved with, and
/// `currency(of:)` holds it against the one there is when the user
/// confirms and when the plan stages. An operation finishing is never
/// held.
final class PackageQueue {
    static let shared = PackageQueue()

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
    /// The packages Patch has adapted, each with the tree staging hands the
    /// helper and the control paragraph every solve from then on reads in
    /// place of the adapter's preview; pruned as a package leaves the plan.
    private(set) var patched: [Package: PatchedPackage] = [:]
    /// Patch is running: nothing else starts one.
    private var patching = false

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

    private let allowSystemRemovalStore = Stored(key: "package.allowSystemRemoval", defaultValue: false)

    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    /// The last pool read, and the generation of the read: a read started
    /// later replaces it, one started earlier never does.
    private var pool: (generation: Int, value: ResolutionPool)?
    /// The preflight's read in flight: a solve waits for it rather than
    /// reading the same pool again.
    private var poolRead: (generation: Int, task: Task<ResolutionPool?, Never>, awaited: Bool)?
    /// The packages moved and the preflight waits for them to settle.
    private var preflightDelay: Task<Void, Never>?
    private var generations = 0
    /// A repository was written while the repositories refreshed and the
    /// queue has not been solved again for it: this waits out the refresh
    /// and solves it then, unless word of the last write does first.
    private var heldChange: Task<Void, Never>?

    private init() {
        NotificationCenter.default.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.packagesChanged() }
            .store(in: &subscriptions)
        // the pool holds the whole catalogue: the next solve reads it again
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dropPool() }
            .store(in: &subscriptions)
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
        guard proposal.revision == revision, !Installer.shared.inProcessingQueue else { return false }
        actions = proposal.actions
        cleanup = proposal.cleanup
        plan = proposal.plan
        notices = proposal.notices
        blocked = nil
        changed()
        // this starts what the plan needs and stops what it no longer does,
        // except a download Download Archive is waiting for
        Downloads.shared.download(proposal.plan?.install ?? [])
        prunePatched()
        return true
    }

    // MARK: - Patch

    /// A package Patch adapted: the prepared tree staging hands the helper,
    /// the digest of its rewritten manifest, and the control paragraph the
    /// adapter left it with.
    struct PatchedPackage {
        let directory: URL
        let manifestDigest: String
        let control: [String: String]
    }

    /// What solving again after Patch did to the queue; both empty when the
    /// plan is what it was.
    struct PatchOutcome {
        let left: [Package]
        let joined: [Package]
    }

    struct PatchFailure: Error {
        let message: String
        /// A file of the plan is not on disk any more (a cached download
        /// that no longer matched its hash was discarded): downloading
        /// again is what repeats this, not patching again.
        var missingDownload = false
    }

    /// The adapted packages the plan installs that Patch has not been
    /// through. The queue page offers Patch while there are any and Execute
    /// once there are none.
    var unpatched: [Package] {
        guard let plan else { return [] }
        return plan.install.filter { plan.snapshot.adapts($0) && patched[$0] == nil }
    }

    /// Adapts every unpatched package of the plan, each file already on
    /// disk, and keeps the trees for staging. The resolver solves an
    /// adapted package as its adapter's preview says before anything is
    /// downloaded, the compat layer in front of its Pre-Depends; the queue
    /// is then solved again with the control paragraphs `adapt` wrote. One
    /// whose file needs no compat layer (a theme: no Mach-O, no code for it
    /// to load) has none there, so what the preview brought in,
    /// rootless-compat and patchloader, leaves the queue before it runs,
    /// and the outcome says so. The paragraph is the one on the tree that
    /// installs, so the plan cannot disagree with what is installed. A
    /// failure keeps what was patched before it. A queue that moved while
    /// its files were adapted (the user's own change, a catalogue refresh)
    /// is not Patch's doing and is not reported as its outcome: what the new
    /// plan still has unpatched is the next tap's.
    func patch() async -> Result<PatchOutcome, PatchFailure> {
        guard let before = plan else { return .success(PatchOutcome(left: [], joined: [])) }
        guard !patching, !Installer.shared.inProcessingQueue else {
            return .failure(PatchFailure(message: Self.busy.message))
        }
        patching = true
        defer { patching = false }
        let location = Installer.shared.workingLocation.appendingPathComponent("Patched")
        var moved = false
        for package in unpatched {
            guard plan?.id == before.id else {
                moved = true
                break
            }
            var file = package.localFileURL
            if file == nil {
                file = await Downloads.shared.downloadedFile(for: package)
            }
            guard let file else {
                return .failure(PatchFailure(
                    message: String(localized: "The download was interrupted."),
                    missingDownload: true
                ))
            }
            do {
                patched[package] = try await Self.adapt(file, in: location.appendingPathComponent(UUID().uuidString))
            } catch {
                Dog.shared.join(self, "cannot patch \(package.identity): \(error)", level: .error)
                return .failure(PatchFailure(
                    message: (error as? AdaptationFailure)?.report
                        ?? String(localized: "Unable to patch \(package.identity). Try again.")
                ))
            }
        }
        moved = moved || plan?.id != before.id
        // the plan was solved under less than this: a proposal made before
        // it no longer commits, and is solved again. A solve the packages
        // moving under it threw away is tried again; one that failed is the
        // queue's `blocked`, which the page shows
        var tries = 0
        while let plan, !isSolvedAsPatched(plan), blocked == nil, tries < 3 {
            tries += 1
            changed()
            refreshTask?.cancel()
            let task = Task { await refresh(force: true) }
            refreshTask = task
            await task.value
            // a refresh the packages moving started in its place
            await settled()
        }
        // a package that left the queue while it was being patched
        prunePatched()
        guard !moved else { return .success(PatchOutcome(left: [], joined: [])) }
        let after = plan
        func touched(_ plan: ResolutionPlan?) -> [Package] {
            plan.map { $0.install + $0.remove } ?? []
        }
        let was = Set(touched(before).map(\.identity))
        let now = Set(touched(after).map(\.identity))
        return .success(PatchOutcome(
            left: touched(before).filter { !now.contains($0.identity) },
            joined: touched(after).filter { !was.contains($0.identity) }
        ))
    }

    /// Trees of packages the plan no longer installs go, off the main actor:
    /// a theme is thousands of files.
    private func prunePatched() {
        let installing = Set(plan?.install ?? [])
        let stale = patched.filter { !installing.contains($0.key) }
        guard !stale.isEmpty else { return }
        for package in stale.keys {
            patched[package] = nil
        }
        let directories = stale.values.map(\.directory)
        Task.detached {
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Whether every package of the plan that Patch has been through was
    /// solved with the control paragraph it was left with.
    private func isSolvedAsPatched(_ plan: ResolutionPlan) -> Bool {
        plan.install.allSatisfy { plan.snapshot.adaptedManifests[$0] == patched[$0]?.control }
    }

    /// Prepares the file and adapts it in `directory`, as staging would.
    @concurrent
    private nonisolated static func adapt(_ file: URL, in directory: URL) async throws -> PatchedPackage {
        do {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var digest = try ArchiveStream.prepareDebianPackage(at: file, in: directory)
            if let adapted = try PackageAdapters.installed.adapt(
                preparedPackageAt: directory,
                on: PackagedArchitecture.architecture
            ) {
                digest = adapted
            }
            return try PatchedPackage(
                directory: directory,
                manifestDigest: digest,
                control: PackageAdapters.installed.control(ofPreparedPackageAt: directory)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The queue touches the package: asked for, ticked, or brought in.
    func isQueued(_ identity: String) -> Bool {
        actions.contains { $0.identity == identity }
            || cleanup.contains(identity)
            || plan.map { ($0.install + $0.remove).contains { $0.identity == identity } } ?? false
    }

    /// The package the queue installs, including its source file.
    func queuedPackage(of identity: String) -> Package? {
        plan?.install.first { $0.identity == identity }
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
        guard !Installer.shared.inProcessingQueue else { return }
        actions = []
        cleanup = []
        plan = nil
        notices = []
        blocked = nil
        prunePatched()
        changed()
        Downloads.shared.cancelAll()
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
            packagesChanged(installed: true)
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

    /// The packages moved. A write while the repositories refresh is held
    /// until the last is written, then the queue and an open sheet solve
    /// once. `installed`, an operation that finished, is never held; dpkg's
    /// status moved some other way is caught when Confirm or staging checks
    /// the plan (`currency(of:)`).
    private func packagesChanged(installed: Bool = false) {
        schedulePreflight()
        if Self.isRefreshing {
            guard installed else { return hold() }
        } else {
            heldChange?.cancel()
            heldChange = nil
        }
        changed()
        guard plan != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    private func hold() {
        guard heldChange == nil else { return }
        heldChange = Task { [weak self] in
            do {
                while Self.isRefreshing {
                    try await Task.sleep(for: Self.settleDelay)
                }
            } catch {
                return
            }
            guard let self else { return }
            heldChange = nil
            packagesChanged()
        }
    }

    /// Staging found the plan out of date: the queue is solved again now,
    /// against the catalogue as it is even while the repositories refresh,
    /// so Retry stages what that gives and not the same plan again.
    func solveAgainNow() {
        if Self.isRefreshing {
            readPool(awaited: true)
        }
        packagesChanged(installed: true)
    }

    /// The packages moved: solve the original requests again. A missing
    /// local file stays requested and fails staging; dropping it here could
    /// let a repository copy satisfy another package's dependency instead.
    /// When solving fails the old plan stays, blocked, with the reason.
    /// `force` solves again even when the packages did not move: the rules
    /// the plan was solved under did.
    private func refresh(force: Bool = false) async {
        guard !Installer.shared.inProcessingQueue, let plan else { return }
        let revision = revision
        // current means the packages did not move and nothing was learned
        // about them since (`patch`)
        if !force, isSolvedAsPatched(plan),
           await (try? Self.isCurrent(plan: plan, index: PackageCenter.default.index)) == true
        {
            return
        }
        guard !Task.isCancelled, revision == self.revision else { return }
        // the request's own lines (held-back updates) outlive a solve; the
        // old plan's go with it and the new plan says its own
        let planned = Self.notices(of: plan)
        let result = await proposal(actions: actions, cleanup: cleanup, notices: notices.filter { !planned.contains($0) })
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

    /// A refusal from the catalogue kept through a refresh is not the last
    /// word: what the request needs may be in a repository written since,
    /// so it is solved once more against the catalogue as it is now.
    private func solve(_ request: ResolutionRequest) async -> Result<ResolutionPlan, ResolutionFailure> {
        let first = await solveOnce(request)
        guard first.refusedPinned, !Task.isCancelled else { return first.result }
        readPool(awaited: true)
        return await solveOnce(request).result
    }

    /// `refusedPinned` when the solver refused the request against a
    /// catalogue kept through a refresh.
    private func solveOnce(
        _ request: ResolutionRequest
    ) async -> (result: Result<ResolutionPlan, ResolutionFailure>, refusedPinned: Bool) {
        guard !Installer.shared.inProcessingQueue else { return (.failure(Self.busy), false) }
        let (prepared, pinned) = await startingPool()
        // the wait is for the pool, and the pool is kept: whoever asked
        // and left since is not solved for
        guard !Task.isCancelled else { return (.failure(ResolutionFailure(.unknown)), false) }
        // read after the wait: the index carries the update settings
        let index = PackageCenter.default.index
        var request = request
        request.allowSystemRemoval = allowSystemRemoval
        generations += 1
        let generation = generations
        do {
            let (plan, read) = try await Self.resolve(
                request: request,
                index: index,
                adaptedManifests: patched.mapValues(\.control),
                pool: prepared,
                pinned: pinned
            )
            adopt(read, generation: generation)
            // the catalogue may have been written since: the plan says
            // which one it was solved with, and `currency(of:)` holds that
            // against the one there is before it is taken or staged
            guard !Installer.shared.inProcessingQueue,
                  try await Self.changes(since: plan, index: PackageCenter.default.index)
                  .isDisjoint(with: [.installed, .settings]),
                  // an operation may have begun during the status check
                  !Installer.shared.inProcessingQueue
            else {
                return (.failure(Self.moved), false)
            }
            return (.success(plan), false)
        } catch is CancellationError {
            // whoever asked has gone and reads nothing of this
            return (.failure(ResolutionFailure(.unknown)), false)
        } catch let refusal as ResolutionFailure {
            Dog.shared.join(self, String(describing: refusal), level: .error)
            return (.failure(refusal), pinned)
        } catch {
            Dog.shared.join(self, String(describing: error), level: .error)
            return (.failure(ResolutionFailure(.unknown)), false)
        }
    }

    // MARK: - Preflight

    /// How long the packages stay still before the pool is read again: a
    /// refresh writes one repository after another.
    private static let settleDelay: Duration = .seconds(2)

    /// The packages moved: the pool is read again once they stop, and not
    /// while a refresh is still writing them or an operation runs, which
    /// moves them again when it ends. Also called once the engines are up.
    func schedulePreflight() {
        preflightDelay?.cancel()
        // a read already going is of packages that have moved since: it
        // would only be thrown away, after seconds of work. One a solve
        // waits on goes on; the solve would only read it again.
        if let read = poolRead, !read.awaited {
            read.task.cancel()
            poolRead = nil
        }
        preflightDelay = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.settleDelay)
                // at launch the refresh of what is out of date is queued a
                // moment after the engines are up: not reading until then
                // keeps a pool that refresh would make stale at once
                while !RepositoryCenter.default.hasQueuedLaunchRefresh
                    || RepositoryCenter.default.obtainUpdateRemain() > 0
                    || Installer.shared.inProcessingQueue
                {
                    try await Task.sleep(for: Self.settleDelay)
                }
            } catch {
                return
            }
            self?.readPool()
        }
    }

    /// Starts reading the pool now, in place of any read already going: the
    /// packages it was started for have moved since.
    /// `awaited` when a solve is about to wait for it: the packages moving
    /// in the meantime do not cancel it.
    @discardableResult
    private func readPool(awaited: Bool = false) -> Task<ResolutionPool?, Never> {
        preflightDelay?.cancel()
        preflightDelay = nil
        poolRead?.task.cancel()
        generations += 1
        let generation = generations
        let index = PackageCenter.default.index
        let manifests = patched.mapValues(\.control)
        let previous = pool?.value
        // nobody waits for it yet; a solve that does raises it to its own
        let task = Task(priority: .utility) { [weak self] () -> ResolutionPool? in
            let read = await Self.readPool(index: index, adaptedManifests: manifests, previous: previous)
            if let self {
                adopt(read, generation: generation)
                if poolRead?.generation == generation {
                    poolRead = nil
                }
            }
            return read
        }
        poolRead = (generation, task, awaited)
        return task
    }

    /// The pool a solve starts from: the read in flight, started now if the
    /// packages moved and the preflight is still waiting, or else the last
    /// one read. It may be out of date all the same (the dpkg status can
    /// change without a word); the solve then reads the one it needs.
    private func preparedPool() async -> ResolutionPool? {
        if preflightDelay != nil, !Installer.shared.inProcessingQueue {
            readPool()
        }
        return await awaitedPool()
    }

    /// The pool a solve starts from, and whether it is pinned: while the
    /// repositories refresh, the last one read (or the read in flight)
    /// even though the catalogue has been written since, since a read in
    /// the middle of a refresh is out of date before it ends.
    private func startingPool() async -> (pool: ResolutionPool?, pinned: Bool) {
        guard Self.isRefreshing else { return await (preparedPool(), false) }
        if pool == nil, poolRead == nil, !Installer.shared.inProcessingQueue {
            readPool()
        }
        return await (awaitedPool(), true)
    }

    /// Reads the catalogue as it is now, refresh or not, for the solves
    /// that follow: the user asked for it after hearing the repositories
    /// changed under their change.
    func readCatalogue() {
        readPool(awaited: true)
    }

    /// The read in flight, or else the last one read.
    private func awaitedPool() async -> ResolutionPool? {
        // a read the packages moving cancelled has a newer one after it
        while let current = poolRead {
            poolRead?.awaited = true
            if let read = await current.task.value {
                return read
            }
            guard poolRead.map({ $0.generation != current.generation }) == true else { break }
        }
        return pool?.value
    }

    private func adopt(_ read: ResolutionPool?, generation: Int) {
        guard let read, generation > pool?.generation ?? 0 else { return }
        pool = (generation, read)
    }

    private func dropPool() {
        preflightDelay?.cancel()
        preflightDelay = nil
        poolRead?.task.cancel()
        poolRead = nil
        pool = nil
    }

    private static var isRefreshing: Bool {
        RepositoryCenter.default.obtainUpdateRemain() > 0
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
        NotificationCenter.default.post(name: .PackageQueueChanged, object: nil)
    }

    /// The plan, and the pool this solve read when `pool` did not serve the
    /// packages as they are: the queue keeps it for the next.
    @concurrent
    private nonisolated static func resolve(
        request: ResolutionRequest,
        index: PackageIndex,
        adaptedManifests: [Package: [String: String]],
        pool: ResolutionPool?,
        pinned: Bool
    ) async throws -> (ResolutionPlan, ResolutionPool?) {
        var snapshot = try index.resolutionSnapshot(reusingCatalogueOf: pool?.snapshot, evenIfWritten: pinned)
        snapshot.adaptedManifests = adaptedManifests
        let served = pool?.serves(snapshot) == true
        var kept = pool
        let plan = try PackageResolver.resolve(request: request, snapshot: snapshot, keeping: &kept)
        // a request for a package outside the catalogue leaves a stale pool
        // as it was, and a stale pool is nothing to keep
        return (plan, !served && kept?.serves(snapshot) == true ? kept : nil)
    }

    /// The pool of the packages as they are, or `previous` when it still
    /// serves them; nil when the read was cancelled or failed, and the next
    /// solve reads it then.
    @concurrent
    private nonisolated static func readPool(
        index: PackageIndex,
        adaptedManifests: [Package: [String: String]],
        previous: ResolutionPool?
    ) async -> ResolutionPool? {
        do {
            var snapshot = try index.resolutionSnapshot(reusingCatalogueOf: previous?.snapshot)
            snapshot.adaptedManifests = adaptedManifests
            if let previous, previous.serves(snapshot) {
                return previous
            }
            return try ResolutionPool(snapshot: snapshot)
        } catch {
            return nil
        }
    }

    @concurrent
    nonisolated static func isCurrent(plan: ResolutionPlan, index: PackageIndex) async throws -> Bool {
        try index.isCurrent(plan.snapshot)
    }

    @concurrent
    private nonisolated static func changes(
        since plan: ResolutionPlan,
        index: PackageIndex
    ) async throws -> ResolutionSnapshot.Changes {
        try index.changes(since: plan.snapshot)
    }

    /// Whether a plan still installs as it was solved.
    nonisolated enum Currency: Equatable {
        /// The installed packages and the settings are as they were, and
        /// so is every package it installs, though a refresh may have
        /// written the catalogue since.
        case current
        /// dpkg's status or a setting moved: the plan is solved again.
        case moved
        /// The repositories no longer offer these as the plan has them.
        case withdrawn([Package])
    }

    @concurrent
    nonisolated static func currency(of plan: ResolutionPlan, index: PackageIndex) async throws -> Currency {
        let changes = try index.changes(since: plan.snapshot)
        guard changes.isDisjoint(with: [.installed, .settings]) else { return .moved }
        guard changes.contains(.catalogue) else { return .current }
        let withdrawn = index.withdrawn(plan.install)
        return withdrawn.isEmpty ? .current : .withdrawn(withdrawn)
    }

    /// The proposal's plan against the packages as they are, for Confirm;
    /// an emptied queue is always current, and a status that cannot be
    /// read is a reason to solve again.
    func currency(of proposal: Proposal) async -> Currency {
        guard let plan = proposal.plan else { return .current }
        return await (try? Self.currency(of: plan, index: PackageCenter.default.index)) ?? .moved
    }
}
