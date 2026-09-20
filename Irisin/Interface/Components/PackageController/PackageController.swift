//
//  PackageController.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/5/3.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AlertController
import AptRepository
import Combine
import PackageDepiction
import SnapKit
import Then
import UIKit
import WebKit

class PackageController: UIViewController {
    var packageObject = Package(identity: "")
    private var subscriptions = Set<AnyCancellable>()

    convenience init(package: Package) {
        self.init(nibName: nil, bundle: nil)
        packageObject = package
    }

    private func leaveForRemovedRepository() {
        if let navigator = navigationController, navigator.viewControllers.first !== self {
            navigator.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: PROPERTY

    /// The gutter around the photo.
    let inset: CGFloat = 16

    /// What the page is made of, top to bottom. Each row is a view the page
    /// owns, in a cell around it (`PackageRowCell`).
    enum Row: String, CaseIterable {
        /// The header photo on its ground.
        case artwork
        /// The package's icon, name, version and button.
        case banner
        /// How Auto Translate is going; there only while it has something
        /// to say.
        case translationStatus
        case depiction
        /// The architecture, under the depiction.
        case footer
    }

    /// The page is a list of `Row`, so a row that comes, goes or changes
    /// its height is a snapshot and the table moves the rest.
    let tableView = UITableView(frame: .zero, style: .plain).then {
        $0.backgroundColor = .plainBackground
        $0.separatorStyle = .none
        $0.allowsSelection = false
        $0.rowHeight = UITableView.automaticDimension
        $0.estimatedRowHeight = 200
        // a row follows the constraints inside it (the photo's height, a
        // depiction that grew) without being told
        $0.selfSizingInvalidation = .enabledIncludingConstraints
        $0.sectionHeaderTopPadding = 0
        for row in Row.allCases {
            $0.register(PackageRowCell.self, forCellReuseIdentifier: row.rawValue)
        }
    }

    private(set) lazy var dataSource = UITableViewDiffableDataSource<Int, Row>(
        tableView: tableView
    ) { [weak self] tableView, indexPath, row in
        let cell = tableView.dequeueReusableCell(withIdentifier: row.rawValue, for: indexPath)
        guard let self, let cell = cell as? PackageRowCell else { return cell }
        fill(cell, with: row)
        return cell
    }.then {
        $0.defaultRowAnimation = .fade
    }

    /// The ground behind the photo, a step below the card in both modes. It
    /// reaches far above the content so it shows through the translucent bar
    /// and fills an overscroll.
    let bannerBackdrop = UIView().then {
        $0.backgroundColor = .panelBackground
        $0.autoresizingMask = .flexibleWidth
    }

    /// The header photo, at most a third of the page tall
    /// (`updatePreferredImageHeight`), over the package's name in
    /// handwriting that shows until it arrives.
    let bannerArtwork = PackageArtworkView().then {
        $0.layer.cornerRadius = 16
        $0.layer.cornerCurve = .continuous
        $0.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    var bannerPackageView = PackageBannerView(package: Package(identity: ""))
    var preferredBannerHeight: CGFloat = 120

    /// How long after it loads a page takes to settle: a photo that must be
    /// fetched is not asked for sooner, so the banner resizes on a page
    /// that has stopped moving.
    private static let settlingTime: Duration = .seconds(2.5)

    /// When this page has settled, counted from `viewDidLoad`. A cached
    /// photo does not wait for it.
    private(set) var bannerPhotoDeadline = ContinuousClock.now

    /// The size of the photo the banner is laid out for, which follows the
    /// photo on show through `resizeBanner`: a layout pass that happens to
    /// run as a photo arrives, perhaps with animations off, never resizes
    /// the banner for it.
    private var bannerPhotoSize: CGSize?

    /// The height the photo is laid out at, the one thing a row's height
    /// hangs on that is not its content's own.
    private var artworkHeight: Constraint?

    var depictionView = UIView() {
        didSet {
            // settled at once: a depiction that lands during another
            // animation (a sheet going down) must not slide into place
            applyRows(reconfiguring: [.depiction, .footer], animated: false)
        }
    }

    private func fill(_ cell: PackageRowCell, with row: Row) {
        cell.onHeightMismatch = { [weak self] height in
            self?.setNeedsRowHeights(for: row, wanting: height)
        }
        switch row {
        case .artwork:
            // the content meets the photo with no gap between them
            cell.backgroundColor = .panelBackground
            cell.host(bannerArtwork, insets: UIEdgeInsets(top: inset, left: inset, bottom: 0, right: inset))
        case .banner:
            cell.host(bannerPackageView)
        case .translationStatus:
            cell.host(translationStatusView)
        case .depiction:
            // the depiction is Auto Layout throughout: its height is its own
            cell.host(depictionView)
        case .footer:
            depictionFooter.text = footerText()
            // The page ends well below its last line so the floating bar
            // never covers it.
            cell.host(
                depictionFooter,
                insets: UIEdgeInsets(top: inset, left: inset, bottom: inset + 128, right: inset)
            )
        }
    }

    /// Brings the list to the rows the page has now. `reconfiguring` names
    /// rows that stay but whose view was exchanged or whose text changed.
    func applyRows(reconfiguring changed: [Row] = [], animated: Bool) {
        guard isViewLoaded else { return }
        var rows: [Row] = [.artwork, .banner]
        if translationStatusView.status != .none {
            rows.append(.translationStatus)
        }
        rows += [.depiction, .footer]
        // a row whose view or text changed may ask for any height again
        changed.forEach { heightsAskedFor[$0] = nil }
        let before = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows)
        snapshot.reconfigureItems(changed.filter { before.contains($0) && rows.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private var rowHeightsAreStale = false

    /// The height each row last asked to be measured for. A row that asks
    /// for the same height again was measured and did not get it, and
    /// measuring once more would only have it ask again, for ever.
    private var heightsAskedFor: [Row: CGFloat] = [:]

    /// A view outgrew its row or fell short of it: the rows are measured
    /// again, once for however many said so in this pass, and in place, as
    /// the scroll view this page used to be would have followed.
    private func setNeedsRowHeights(for row: Row, wanting height: CGFloat) {
        let height = height.rounded()
        guard heightsAskedFor[row] != height else { return }
        heightsAskedFor[row] = height
        guard !rowHeightsAreStale else { return }
        rowHeightsAreStale = true
        Task { [weak self] in
            guard let self else { return }
            rowHeightsAreStale = false
            UIView.performWithoutAnimation {
                self.measureRows(animated: false)
            }
        }
    }

    private var isMeasuringRows = false

    /// Has the table measure every row again, through a snapshot like every
    /// other change to the list: iOS 16 throws from any of the table's own
    /// mutation calls, an empty batch of updates included, while its data
    /// source is a diffable one (issue 125). A row that says it is the
    /// wrong height while this lays it out is not measured from inside
    /// the measuring.
    private func measureRows(animated: Bool) {
        guard isViewLoaded, !isMeasuringRows else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        isMeasuringRows = true
        defer { isMeasuringRows = false }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func footerText() -> String {
        let environment = AptEnvironment.current
        let differs = !packageObject.supports(architecture: environment.deviceArchitecture)
        var footer = String(localized: "Architecture: \(packageObject.architectures.joined(separator: ", "))")
        if differs, packageObject.supports(anyOf: environment.installableArchitectures) {
            footer += "\n" + String(localized: "Installs in compatibility mode.")
        }
        if depictionIsPartial {
            footer = String(localized: "Some of this package's content cannot be shown.") + "\n" + footer
        }
        return footer
    }

    /// The page becomes another version of the same package, in place. The
    /// photo and the depiction on show stay until the new depiction has
    /// loaded, so nothing falls back to a placeholder in between.
    func show(_ package: Package) {
        packageObject = package
        bannerPackageView = PackageBannerView(package: package)
        applyRows(reconfiguring: [.banner], animated: false)
        navigationItem.rightBarButtonItem?.menu = bannerPackageView.actionMenu
        bannerArtwork.write(nameOf: bannerPackageView.package)
        downloadDepictionIfAvailable()
    }

    /// Whether the depiction on show named views this build could not build.
    var depictionIsPartial = false

    /// The translation of the depiction on show, while it is on its way. A
    /// new depiction (another version of the package) cancels it.
    var depictionTranslation: Task<Void, Never>?

    /// The alert the translation on its way waits behind, when the menu
    /// asked for it. One left behind by a translation since replaced is no
    /// longer this, and its Cancel cancels nothing.
    weak var translationAlert: AlertViewController?

    /// The depiction as its author wrote it, which every translation of the
    /// page is made from.
    var depictionOnShow: (json: [String: Any], tintColor: UIColor)?

    /// How the page reads: what the Translate menu has checked. It starts
    /// where Auto Translate puts it and is this page's alone after that.
    var translationMode: TranslationMode = AutomaticTranslation.isEnabled ? .translated : .original

    /// How the depiction on show reads, which the checkmark goes back to
    /// when a translation is cancelled or fails.
    var translationModeOnShow: TranslationMode = .original

    /// The language the page is read from; nil lets the engine tell.
    var translationSource: Locale?

    /// Says how Auto Translate is going, between the banner and the
    /// depiction (`showTranslationStatus`).
    let translationStatusView = TranslationStatusView()

    /// Closes the card under the depiction, in the style of the home page
    /// footer: the architecture the package was built for, under a notice
    /// when the depiction is partial.
    let depictionFooter = UILabel().then {
        $0.font = .footnote
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .plainBackground

        bannerPhotoDeadline = .now + Self.settlingTime
        bannerPackageView = PackageBannerView(package: packageObject)
        title = PackageCenter.default.name(of: describedPackage)
        navigationItem.largeTitleDisplayMode = .never
        // a page for a repository the user just deleted must not stay up
        // offering an install from a catalogue that is gone
        if let repository = packageObject.repoRef {
            NotificationCenter.default.publisher(for: RepositoryCenter.registrationUpdate)
                .receive(on: DispatchQueue.main)
                .filter { _ in RepositoryCenter.default.obtainImmutableRepository(withUrl: repository) == nil }
                .first()
                .sink { [weak self] _ in self?.leaveForRemovedRepository() }
                .store(in: &subscriptions)
        }
        // the same menu the banner button opens on a long press
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: bannerPackageView.actionMenu
        ).then { $0.tintColor = .textTitle }

        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        tableView.insertSubview(bannerBackdrop, at: 0)
        bannerArtwork.write(nameOf: bannerPackageView.package)
        bannerArtwork.snp.makeConstraints { x in
            artworkHeight = x.height.equalTo(preferredBannerHeight).constraint
        }

        bannerArtwork.imageView.publisher(for: \.image)
            .map { $0?.size }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.bannerPhotoSize = size
                self?.resizeBanner()
            }
            .store(in: &subscriptions)

        depictionView = defaultDepiction()

        downloadDepictionIfAvailable()
    }

    /// The width the rows were last laid out at.
    private var laidOutWidth: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bannerBackdrop.frame = CGRect(x: 0, y: -1000, width: tableView.bounds.width, height: 1000)
        if laidOutWidth != tableView.bounds.width {
            // every height is another at another width
            laidOutWidth = tableView.bounds.width
            heightsAskedFor.removeAll()
        }
        resizeBanner()
    }

    /// A dpkg row: the page was opened from the installed list, not from a
    /// repository or a `.deb` on disk.
    private var showsInstalledRow: Bool {
        packageObject.repoRef == nil && packageObject.localFileURL == nil
    }

    /// What the title and the depiction are made from: a dpkg row is
    /// described by its install origin, the repository's record of the same
    /// version, which names the depiction and the icon dpkg's does not.
    var describedPackage: Package {
        PackageCenter.default.obtainDescription(of: packageObject)
    }

    /// Refresh installed status after a transaction. An explicitly opened
    /// package keeps its version, source and metadata while this page lives.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if showsInstalledRow,
           let fresh = PackageCenter.default.obtainPackageInstallationInfo(with: packageObject.identity)?.representObject
        {
            packageObject = fresh
        }
        // settled before the button animates: a page whose first layout
        // happens inside an animation block slides every view in from zero
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
        bannerPackageView.updateButton()
    }

    /// The page is on screen. Before that a photo lands where it belongs;
    /// after, one that arrives moves the banner in front of the user.
    private(set) var hasAppeared = false

    /// A pushed page for a dpkg row that dpkg no longer has, and that no
    /// repository offers either, shows a package that is gone: leave it.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        guard showsInstalledRow,
              let navigator = navigationController, navigator.viewControllers.first !== self,
              PackageCenter.default.obtainPackageInstallationInfo(with: packageObject.identity) == nil,
              PackageCenter.default.obtainPackageSummary(with: packageObject.identity).isEmpty
        else { return }
        navigator.popViewController(animated: true)
    }

    /// The banner height the constraints were last set to.
    private var appliedBannerHeight: CGFloat?

    /// Brings the banner to its preferred height: at once before the page
    /// shows, in an animation after.
    private func resizeBanner() {
        updatePreferredImageHeight()
        guard preferredBannerHeight != appliedBannerHeight else {
            return
        }
        appliedBannerHeight = preferredBannerHeight
        artworkHeight?.update(offset: preferredBannerHeight)
        heightsAskedFor[.artwork] = nil
        guard hasAppeared else {
            UIView.performWithoutAnimation {
                measureRows(animated: false)
                tableView.layoutIfNeeded()
            }
            return
        }
        let artworkSize = bannerArtwork.bounds.size
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0.8,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: { [self] in
                measureRows(animated: true)
                tableView.layoutIfNeeded()
                bannerArtwork.carryHandwriting(from: artworkSize)
            }
        )
    }

    /// A photo follows its own ratio, capped at a third of the page; a photo
    /// taller than that is cropped by its aspect fill. The handwriting sits
    /// in a 5:2 strip, capped at a quarter: on a wide page it is only a name.
    func updatePreferredImageHeight() {
        let width = view.frame.width - inset * 2
        preferredBannerHeight = if let size = bannerPhotoSize, size.width > 0 {
            min(width * size.height / size.width, view.frame.height / 3)
        } else {
            min(width * 2 / 5, view.frame.height / 4)
        }
    }
}
