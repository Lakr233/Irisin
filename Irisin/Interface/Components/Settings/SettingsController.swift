//
//  SettingsController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import IrisinProtocol
import SnapKit
import Then
import UIKit

/// Settings: the vendor accounts of the paid repositories, inset groups of
/// rows, and a footer saying what this build is. Each row is a
/// `SettingsItem`; the cells read their values through it and are
/// reconfigured whenever a value changes.
class SettingsController: UITableViewController {
    private var subscriptions = Set<AnyCancellable>()

    nonisolated enum Section: Hashable {
        case accounts
        case repositories
        case packages
        case downloads
        case system
        case support
    }

    nonisolated enum Row: Hashable {
        case item(String)
        case account(URL)
    }

    private var items: [String: SettingsItem] = [:]

    private let listUpdates = WindowedListUpdates()

    private lazy var dataSource = EditableTableDiffableDataSource<Section, Row>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, row in
        switch row {
        case let .account(url):
            let cell = tableView.dequeueReusableCell(withIdentifier: "account", for: indexPath) as! SettingsAccountCell
            if let repo = RepositoryCenter.default.repositories[url] {
                cell.configure(repo: repo)
            }
            return cell
        case let .item(id):
            guard let item = items[id] else { return UITableViewCell() }
            let identifier = switch item.kind {
            case .disclosure: "disclosure"
            case .value: "value"
            case .toggle: "toggle"
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath) as! SettingsCell
            cell.configure(with: item)
            return cell
        }
    }

    private let footer = SettingsFooterView()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Welcome Page"),
                    image: UIImage(systemName: "hand.wave")
                ) { [weak self] _ in
                    self?.present(WelcomeController.makeNavigator(), animated: true)
                },
                UIAction(
                    title: String(localized: "System Settings"),
                    image: UIImage(systemName: "gear")
                ) { _ in
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                },
                // below a divider: the files this app hands out
                UIMenu(options: .displayInline, children: [
                    ExportFile.menu(from: self) { [weak self] in
                        (self?.navigationItem.rightBarButtonItem).map { PopoverAnchor($0) }
                    },
                ]),
            ])
        ).then { $0.accessibilityLabel = String(localized: "More") }
        // the grouped ground: the page and the cards match every other
        // inset grouped list in the app
        view.backgroundColor = .groupedBackground

        tableView.register(SettingsDisclosureCell.self, forCellReuseIdentifier: "disclosure")
        tableView.register(SettingsValueCell.self, forCellReuseIdentifier: "value")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: "toggle")
        tableView.register(SettingsAccountCell.self, forCellReuseIdentifier: "account")
        tableView.dataSource = dataSource
        tableView.separatorStyle = .none
        dataSource.headerTitle = { section in
            switch section {
            case .accounts: String(localized: "Vendor Accounts")
            case .repositories: String(localized: "Repositories")
            case .packages: String(localized: "Packages")
            case .downloads: String(localized: "Downloads")
            case .system: String(localized: "System")
            case .support: String(localized: "Support")
            }
        }

        footer.onLicense = { [weak self] in self?.present(next: LicenseController()) }
        tableView.tableFooterView = footer

        for item in repositoryItems() + packageItems() + downloadItems() + systemItems() + supportItems() {
            items[item.id] = item
        }
        applySnapshot(animatingDifferences: false)

        NotificationCenter.default.publisher(for: .SettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadValues() }
            .store(in: &subscriptions)
        // The daemon answers a moment after launch; the footer says so.
        PrivilegedBackend.backendUpdates
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.footer.refresh() }
            .store(in: &subscriptions)
        Publishers.MergeMany([
            RepositoryCenter.registrationUpdate,
            RepositoryCenter.metadataUpdate,
            .RepositoryPaymentChanged,
        ].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .filter { !$0.isRepositoryProgress }
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.applySnapshot(animatingDifferences: true) }
        .store(in: &subscriptions)
    }

    /// The account rows follow the repositories; the group is left out when
    /// none of them has a vendor. Rows that stay are reconfigured: the icon,
    /// the name or the account may have changed.
    private func applySnapshot(animatingDifferences: Bool) {
        listUpdates.apply("rows", to: tableView, animated: animatingDifferences) { [weak self] animated in
            self?.applyRows(animated: animated)
        }
    }

    private func applyRows(animated animatingDifferences: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let accounts = Self.paidRepositories().map { Row.account($0.url) }
        if !accounts.isEmpty {
            snapshot.appendSections([.accounts])
            snapshot.appendItems(accounts, toSection: .accounts)
        }
        for (section, list) in [
            (Section.repositories, repositoryItems()),
            (.packages, packageItems()),
            (.downloads, downloadItems()),
            (.system, systemItems()),
            (.support, supportItems()),
        ] {
            snapshot.appendSections([section])
            snapshot.appendItems(list.map { Row.item($0.id) }, toSection: section)
        }
        if animatingDifferences {
            snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        }
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = footer.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if footer.frame.size != CGSize(width: width, height: height) {
            footer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableFooterView = footer
        }
    }

    // MARK: - VALUES

    /// Every row reads its value again; a change anywhere is a change here.
    func dispatchValueUpdate() {
        NotificationCenter.default.post(name: .SettingsDidChange, object: nil)
    }

    private func reloadValues() {
        listUpdates.apply("values", to: tableView, animated: false) { [weak self] _ in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
                if case .item = $0 {
                    true
                } else {
                    false
                }
            })
            dataSource.apply(snapshot, animatingDifferences: false)
            footer.refresh()
        }
    }

    /// A one-item menu: tapping the row asks once more before `confirm` runs.
    func confirmMenu(_ text: String, confirm: @escaping () -> Void) -> [UIMenuElement] {
        [UIAction(title: text, attributes: .destructive) { _ in confirm() }]
    }

    /// Suspends the app and asks the daemon for a job that ends it: a
    /// respring or safe mode. The second is a moment later so the suspend
    /// lands first. Without a daemon there is nothing to ask, and the app
    /// says so instead of leaving.
    static func leaveApplication(with job: InstallerJob, from controller: UIViewController?) {
        guard case .daemon = PrivilegedBackend.backend else {
            controller?.presentNotice(
                title: "Browsing Only",
                message: "Install the Irisin package to use this action."
            )
            return
        }
        UIApplication.prepareForExitAndSuspend()
        Task {
            try? await Task.sleep(seconds: 1)
            await PrivilegedBackend.run(job)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        listUpdates.applyPending()
        // the sizes on the rows are read when configured; coming back to
        // this screen after a download must not show the old ones
        dispatchValueUpdate()
    }

    // MARK: - TABLE VIEW

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .item(id):
            guard let item = items[id], item.kind == .disclosure, item.menu == nil else { return }
            item.action?()
        case let .account(url):
            // a signed-in row is covered by its menu button and never gets here
            guard let repo = RepositoryCenter.default.repositories[url] else { return }
            VendorAccount.shared.startUserAuthenticate(
                window: view.window ?? UIWindow(),
                controller: self,
                repoUrl: repo.url
            ) {}
        case nil:
            break
        }
    }
}

/// License, then what this build is.
final class SettingsFooterView: UIView {
    var onLicense: (() -> Void)?

    private let licenseButton = UIButton(type: .system).then {
        $0.titleLabel?.font = .rounded(.caption, emphasized: true)
        $0.setTitle(String(localized: "License"), for: .normal)
        $0.contentHorizontalAlignment = .leading
    }

    private let label = UILabel().then {
        $0.font = .rounded(.caption2)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }

    init() {
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [licenseButton, label]).then {
            $0.axis = .vertical
            $0.alignment = .leading
            $0.spacing = 8
        }
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(12)
            x.leading.trailing.equalToSuperview().inset(32)
            // below required: the table holds the footer at its last frame
            // until the controller measures it again
            x.bottom.equalToSuperview().inset(24).priority(999)
        }
        licenseButton.addTarget(self, action: #selector(license), for: .touchUpInside)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// What this build is and what it runs on: version and build number,
    /// the architecture the package was built for (or the one detected
    /// when it was not packaged), the architectures an adapter lets it
    /// install, the device, and the daemon's answer with its install root.
    func refresh() {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let architecture = PackagedArchitecture.architecture
        let layout = JailbreakRoot.isRoothide ? "roothide" : "rootless"
        var lines = [
            "\(Bundle.main.bundleIdentifier ?? "wiki.qaq.irisin") \(appVersion) (\(build))",
            "\(architecture) · \(layout)",
        ]
        let adapted = AptRepositoryBootstrap.installableArchitectures.subtracting([architecture])
        if !adapted.isEmpty {
            lines.append(String(localized: "Also installs packages for \(adapted.sorted().joined(separator: ", "))"))
        }
        lines.append("iOS \(DeviceIdentity.firmware) · \(DeviceIdentity.machine)")
        lines.append(PrivilegedBackend.localizedStatus)
        label.text = lines.joined(separator: "\n")
    }

    @objc
    private func license() {
        onLicense?()
    }
}
