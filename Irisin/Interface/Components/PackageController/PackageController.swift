//
//  PackageController.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/5/3.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import PackageDepiction
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

    let container = UIScrollView()

    /// The ground behind the photo, a step below the card in both modes. It
    /// reaches far above the content so it shows through the translucent bar
    /// and fills an overscroll.
    let bannerBackdrop = UIView().then {
        $0.backgroundColor = .panelBackground
    }

    /// The header photo, at most a third of the page tall
    /// (`updatePreferredImageHeight`), over the package's name in
    /// handwriting that shows until it arrives.
    let bannerArtwork = ArtworkView().then {
        $0.layer.cornerRadius = 16
        $0.layer.cornerCurve = .continuous
        $0.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    /// The content below the photo: the package header, then the depiction.
    let card = UIView().then {
        $0.backgroundColor = .plainBackground
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

    var depictionView = UIView() {
        didSet {
            oldValue.removeFromSuperview()
            card.addSubview(depictionView)
            // the depiction is Auto Layout throughout: its height is its own
            depictionView.snp.makeConstraints { x in
                x.top.equalTo(self.bannerPackageView.snp.bottom)
                x.left.right.equalToSuperview()
            }
            depictionFooter.attributedText = footerText()
            card.addSubview(depictionFooter)
            // The page ends well below its last line so the floating bar
            // never covers it.
            depictionFooter.snp.remakeConstraints { x in
                x.top.equalTo(depictionView.snp.bottom).offset(inset)
                x.left.right.equalToSuperview().inset(inset)
                x.bottom.equalToSuperview().inset(inset + 128)
            }
            // settled at once: a depiction that lands during another
            // animation (a sheet going down) must not slide into place
            UIView.performWithoutAnimation { card.layoutIfNeeded() }
        }
    }

    private func footerText() -> NSAttributedString {
        let environment = AptEnvironment.current
        let device = environment.deviceArchitecture
        let differs = !packageObject.supports(architecture: device)
        let marked = NSMutableAttributedString()
        for (index, architecture) in packageObject.architectures.enumerated() {
            if index > 0 {
                marked.append(NSAttributedString(string: ", "))
            }
            let runs = differs
                ? ArchitectureDifference.runs(of: architecture, against: device)
                : [.same(architecture)]
            for run in runs {
                switch run {
                case let .same(text):
                    marked.append(NSAttributedString(string: text))
                case let .extra(text):
                    marked.append(NSAttributedString(string: text, attributes: [
                        .foregroundColor: UIColor.architectureMismatch,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ]))
                case let .missing(text):
                    marked.append(NSAttributedString(string: text, attributes: [
                        .foregroundColor: UIColor.architectureMismatch,
                    ]))
                }
            }
        }
        // the sentence is the catalog's; the architectures go where it puts them
        let placeholder = "\u{FFFC}"
        let footer = NSMutableAttributedString(string: String(localized: "Architecture: \(placeholder)"))
        footer.replaceCharacters(in: (footer.string as NSString).range(of: placeholder), with: marked)
        if differs, packageObject.supports(anyOf: environment.installableArchitectures) {
            footer.append(NSAttributedString(string: "\n" + String(localized: "Installs in compatibility mode.")))
        }
        if depictionIsPartial {
            footer.insert(
                NSAttributedString(string: String(localized: "Some of this package's content cannot be shown.") + "\n"),
                at: 0
            )
        }
        return footer
    }

    /// The page becomes another version of the same package, in place. The
    /// photo and the depiction on show stay until the new depiction has
    /// loaded, so nothing falls back to a placeholder in between.
    func show(_ package: Package) {
        packageObject = package
        bannerPackageView.removeFromSuperview()
        bannerPackageView = PackageBannerView(package: package)
        card.addSubview(bannerPackageView)
        bannerPackageView.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.height.equalTo(80)
        }
        navigationItem.rightBarButtonItem?.menu = bannerPackageView.actionMenu
        bannerArtwork.write(nameOf: bannerPackageView.package)
        depictionView.snp.remakeConstraints { x in
            x.top.equalTo(self.bannerPackageView.snp.bottom)
            x.left.right.equalToSuperview()
        }
        downloadDepictionIfAvailable()
    }

    /// Whether the depiction on show named views this build could not build.
    var depictionIsPartial = false

    /// The translation of the depiction on show, while it is on its way. A
    /// new depiction (another version of the package) cancels it.
    var depictionTranslation: Task<Void, Never>?

    /// The depiction as its author wrote it, which every translation of the
    /// page is made from.
    var depictionOnShow: (json: [String: Any], tintColor: UIColor)?

    /// How the page reads: what the Translate menu has checked. It starts
    /// where Auto Translate puts it and is this page's alone after that.
    var translationMode: TranslationMode = AutomaticTranslation.isEnabled ? .translated : .original

    /// The language the page is read from; nil lets the engine tell.
    var translationSource: Locale?

    /// Closes the card under the depiction, in the style of the home page
    /// footer: the architecture the package was built for, under a notice
    /// when the depiction is partial. One the device does not run is read
    /// against the device's like a diff, in red: the letters it has too
    /// many struck through, the ones it lacks put where they belong.
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

        view.addSubview(container)
        container.alwaysBounceVertical = true
        container.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        container.contentLayoutGuide.snp.makeConstraints { x in
            x.width.equalTo(container.frameLayoutGuide)
        }

        container.addSubview(bannerBackdrop)
        container.addSubview(bannerArtwork)
        container.addSubview(card)
        card.addSubview(bannerPackageView)
        bannerArtwork.write(nameOf: bannerPackageView.package)

        let content = container.contentLayoutGuide
        bannerArtwork.snp.makeConstraints { x in
            x.top.leading.trailing.equalTo(content).inset(inset)
            x.height.equalTo(preferredBannerHeight)
        }
        // the content meets the photo with no gap between them
        card.snp.makeConstraints { x in
            x.top.equalTo(bannerArtwork.snp.bottom)
            x.leading.trailing.equalTo(content)
            x.bottom.equalTo(content)
        }
        bannerBackdrop.snp.makeConstraints { x in
            x.top.equalTo(content).offset(-1000)
            x.leading.trailing.equalTo(content)
            x.bottom.equalTo(card.snp.top)
        }
        bannerPackageView.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.height.equalTo(80)
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
    private var hasAppeared = false

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeBanner()
    }

    /// Brings the banner to its preferred height: at once before the page
    /// shows, in an animation after.
    private func resizeBanner() {
        updatePreferredImageHeight()
        guard preferredBannerHeight != appliedBannerHeight else {
            return
        }
        appliedBannerHeight = preferredBannerHeight
        guard hasAppeared else {
            UIView.performWithoutAnimation {
                bannerArtwork.snp.updateConstraints { x in
                    x.height.equalTo(preferredBannerHeight)
                }
                container.layoutIfNeeded()
            }
            return
        }
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0.8,
            options: .curveEaseInOut,
            animations: { [self] in
                bannerArtwork.snp.updateConstraints { x in
                    x.height.equalTo(preferredBannerHeight)
                }
                container.layoutIfNeeded()
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
