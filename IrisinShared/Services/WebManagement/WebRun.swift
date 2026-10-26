//
//  WebRun.swift
//  Irisin
//

import AptRepository
import AptResolver
import Dog
import Foundation
import IrisinProtocol
import IrisinWeb

/// The changes a browser asks for, each put to the owner on the device and
/// then carried out: a plan run through the same services the queue page
/// uses, a repository added or removed, a respring. The request answers at
/// once and the page polls it (`WebRequests`); one change at a time.
enum WebRun {
    /// A plan a browser confirmed is downloading, staging or running.
    private(set) static var isRunning = false

    /// Answers with a request now; the owner's answer and `work` follow.
    /// `work` returns why it failed, or nil when it went through.
    static func ask(
        _ question: WebManagement.Question,
        then work: @escaping () async -> String?
    ) -> WebAnswer {
        let web = WebManagement.shared
        guard !web.requests.hasOpen, web.question == nil else {
            return .failure(String(localized: "The device is already asking about another change. Answer it there first."))
        }
        let id = web.requests.add()
        Task {
            guard await web.ask(question) else {
                web.requests.update(id, .declined)
                return
            }
            web.requests.update(id, .running)
            if let failure = await work() {
                web.requests.update(id, .failed, detail: failure)
            } else {
                web.requests.update(id, .done)
            }
        }
        return .result(web.requests.json(id) ?? .null)
    }

    // MARK: - Plan

    /// Puts the queue's plan to the owner, then runs it. `text` is the
    /// plan's id as the page read it: a queue that moved since is not the
    /// plan the page showed, and is shown again rather than run.
    static func confirm(plan text: String) -> WebAnswer {
        guard let plan = PackageQueue.shared.plan, plan.id.uuidString == text else {
            return .failure(String(localized: "The queue changed since the page read it. Review it again."))
        }
        guard !WebCalls.isBusy else { return .failure(WebCalls.busy) }
        if let blocked = PackageQueue.shared.blocked {
            return .failure(blocked)
        }
        return ask(.init(
            title: String(localized: "Change Packages?"),
            lines: lines(of: plan) + PackageQueue.shared.notices,
            confirmTitle: String(localized: "Confirm"),
            destructive: !plan.remove.isEmpty
        )) {
            await run(plan)
        }
    }

    /// What the plan does, a line a package.
    private static func lines(of plan: ResolutionPlan) -> [String] {
        let installed = Dictionary(
            plan.snapshot.installed.map { ($0.identity, $0.latestVersion ?? "") }
        ) { first, _ in first }
        let install = plan.install.map { package -> String in
            let name = PackageCenter.default.name(of: package)
            let version = package.latestVersion ?? ""
            return switch installed[package.identity] {
            case nil: String(localized: "Install \(name) \(version)")
            case version: String(localized: "Reinstall \(name) \(version)")
            default: String(localized: "Update \(name) to \(version)")
            }
        }
        let remove = plan.remove.map { String(localized: "Remove \(PackageCenter.default.name(of: $0))") }
        return install + remove
    }

    /// The plan the owner said yes to, from its downloads to its end, its
    /// lines in the feed the page streams. Why it stopped, or nil.
    private static func run(_ plan: ResolutionPlan) async -> String? {
        let feed = WebManagement.shared.feed
        // before anything awaits: the page that reads the request as running
        // reads this operation's lines and never the last one's
        feed.begin()
        isRunning = true
        defer { isRunning = false }
        func stop(_ reason: String) -> String {
            feed.say(reason)
            feed.end(succeeded: false, status: nil)
            return reason
        }
        let moved = String(localized: "The queue changed since the page read it. Review it again.")

        let pending = plan.install.filter { $0.localFileURL == nil }
        if !pending.isEmpty {
            feed.say(String(localized: "Downloading…"))
            if let failure = await Downloads.shared.awaitFiles(of: pending, in: plan.id) {
                return stop(failure)
            }
        }
        guard PackageQueue.shared.plan?.id == plan.id else { return stop(moved) }

        // A system with no dpkg: Bootstrap Install where the plan allows it,
        // which places every file before any script runs, as the queue page
        // offers first; otherwise the owner hears which packages run scripts.
        var bootstrapInstall = false
        if !QueueInstallChecks.hasDpkg(plan) {
            if plan.allowsBootstrapInstall {
                bootstrapInstall = true
                feed.say(String(localized: "Bootstrap Install places every package's files before any script runs."))
            } else {
                let names = await QueueInstallChecks.packagesRunningScripts(in: plan)
                if !names.isEmpty {
                    let list = ListFormatter.localizedString(byJoining: names)
                    let goOn = await WebManagement.shared.ask(.init(
                        title: String(localized: "Installation Likely to Fail"),
                        lines: [String(localized: "These packages run scripts that this system may not be able to run: \(list). The installation is likely to fail.")],
                        confirmTitle: String(localized: "Install Anyway"),
                        destructive: true
                    ))
                    guard goOn else { return stop(String(localized: "Declined on the device.")) }
                    guard PackageQueue.shared.plan?.id == plan.id else { return stop(moved) }
                }
            }
        }

        feed.say(String(localized: "Preparing the installation…"))
        let payload = await Installer.shared.createOperationPayload(plan: plan, bootstrapInstall: bootstrapInstall)
        guard let payload, !payload.transaction.stages.isEmpty else {
            let report = PackageActionReport.shared.allAvailable()
            return stop(report.isEmpty ? String(localized: "Unable to prepare this operation. Try again.") : report)
        }
        let monitor = Installer.shared.beginOperation(operation: payload)
        let status = await feed.follow(monitor)
        let outcome = await monitor.finished
        switch monitor.ending {
        case .updateApp:
            feed.say(String(localized: "Irisin restarts now. Open it again for a new code."))
        case .reloadHomeScreen:
            feed.say(String(localized: "Changed tweaks take effect after the home screen reloads."))
        case .close:
            break
        }
        feed.end(succeeded: outcome.succeeded, status: status)
        if monitor.ending == .updateApp {
            Task { await leaveForUpdate(registering: payload.transaction.installsSelf) }
        }
        if case let .failed(reason) = outcome {
            return reason
        }
        return nil
    }

    /// The transaction replaced this app: it registers itself, which stops
    /// it, and leaves, as the operation page's Done does after an update.
    /// The page has a moment to read the end first.
    private static func leaveForUpdate(registering: Bool) async {
        try? await Task.sleep(continuousSeconds: 2)
        WebManagement.shared.stop()
        if registering {
            _ = await OwnRegistration.request()
        }
        Dog.shared.join("WebRun", "leaving after an update of Irisin", level: .warning)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        try? await Task.sleep(continuousSeconds: 1)
        exit(0)
    }

    // MARK: - Home screen

    static func respring() -> WebAnswer {
        guard !WebCalls.isBusy else { return .failure(WebCalls.busy) }
        return ask(.init(
            title: String(localized: "Reload Home Screen"),
            lines: [String(localized: "Every app closes, this one too. Open it again for a new code.")],
            confirmTitle: String(localized: "Reload"),
            destructive: true
        )) {
            if case let .failed(reason) = await PrivilegedBackend.runMaintenance(.respring) {
                return reason
            }
            return nil
        }
    }
}
