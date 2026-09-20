//
//  DownloadArchiveController.swift
//  Irisin
//

// preconcurrency: the configuration is a plain static var upstream, only
// ever touched on the main actor here
@preconcurrency import AlertController
import AptRepository
import SnapKit
import Then
import UIKit

/// Download Archive: one package's .deb fetched the way the queue fetches
/// it — the vendor's link for a purchase, the verified download cache when
/// the file is there — on a progress card, then handed to the share sheet.
/// Cancel stops the download unless the queue needs the same file.
final class DownloadArchiveController: UIViewController {
    static func start(for package: Package, from host: UIViewController, anchor: PopoverAnchor?) {
        var store: URL?
        if package.isCommercial {
            guard let signedIn = PackageMenu.signedInStore(of: package, from: host) else { return }
            store = signedIn
        }
        let card = DownloadArchiveController(package: package, store: store, host: host, anchor: anchor)
        host.present(AlertViewController(contentViewController: card), animated: true)
    }

    private let package: Package
    /// The repository to ask for the purchased link; nil for a free package.
    private let store: URL?
    private weak var host: UIViewController?
    /// What the user touched to ask: where the share sheet points on the iPad.
    private let anchor: PopoverAnchor?
    private var work: Task<Void, Never>?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let countLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)

    private init(package: Package, store: URL?, host: UIViewController, anchor: PopoverAnchor?) {
        self.package = package
        self.store = store
        self.host = host
        self.anchor = anchor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        show(message: store == nil ? String(localized: "Preparing…") : String(localized: "Checking Purchase…"))
    }

    /// Not before: a cached file finishes at once, and a card dismissed
    /// while it is still being presented stays on screen.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard work == nil else { return }
        work = Task { [weak self] in await self?.run() }
    }

    // MARK: - Work

    private func run() async {
        var target = package
        if let store {
            let check = await PackageMenu.checkPurchase(of: package, in: store)
            guard case let .purchased(purchased) = check else {
                guard !Task.isCancelled else { return }
                await close()
                if let host {
                    await PackageMenu.present(check, from: host)
                }
                return
            }
            target = purchased
        }
        guard !Task.isCancelled else { return }

        let center = DownloadCenter.shared
        let url = target.obtainDownloadLink()
        center.downloadArchive(target)
        defer { center.release(target) }
        // ponytail: polls four times a second like the queue page; a
        // publisher on the statuses if the tick ever shows
        while center.isDownloading(url) {
            show(center.status(for: url))
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let status = center.status(for: url)
        await close()
        // Cancel may land while the card leaves
        guard !Task.isCancelled else { return }
        guard let file = status?.file, FileManager.default.fileExists(atPath: file.path) else {
            host?.presentNotice(
                title: "Download Failed",
                message: status?.errorDescription ?? String(localized: "The download was interrupted.")
            )
            return
        }
        share(file, of: target)
    }

    private func share(_ file: URL, of package: Package) {
        guard let copy = try? Self.namedCopy(of: file, for: package) else {
            host?.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        guard let host else { return }
        ShareSheet.present([copy], anchor: anchor, from: host)
    }

    /// A copy under the name dpkg-name would give it, so what lands in
    /// Files or AirDrop says what it is.
    nonisolated static func namedCopy(of file: URL, for package: Package) throws -> URL {
        let version = package.latestVersion?.split(separator: ":").last.map(String.init) ?? "0"
        let architecture = package.latestMetadata?["architecture"] ?? "all"
        let name = [package.identity, version, architecture]
            .joined(separator: "_")
            .replacingOccurrences(of: "/", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Archives")
        let copy = directory.appendingPathComponent(name + ".deb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    private func close() async {
        guard let alert = parent, alert.presentingViewController != nil, !alert.isBeingDismissed else { return }
        cancelButton.isEnabled = false
        await alert.dismissFinishing(animated: true)
    }

    // MARK: - Card

    private func show(_ status: DownloadCenter.Status?) {
        guard let status, status.completedBytes > 0 else {
            return show(message: String(localized: "Preparing…"))
        }
        let center = DownloadCenter.shared
        // every byte is in: the file is being hashed, a cached one included
        let verifying = status.completedBytes >= status.totalBytes
        show(
            message: verifying ? String(localized: "Verifying…") : String(localized: "Downloading…"),
            fraction: status.fractionCompleted,
            count: String(localized: "\(center.byteFormat(bytes: status.completedBytes)) of \(center.byteFormat(bytes: status.totalBytes))")
        )
    }

    /// Every line is on the card from the first frame, one line tall, so
    /// nothing here changes its height. A blank count still takes its line.
    private func show(message: String, fraction: Double = 0, count: String = " ") {
        messageLabel.text = message
        countLabel.text = count
        bar.moveProgress(to: Float(fraction))
    }

    private func build() {
        view.backgroundColor = AlertControllerConfiguration.backgroundColor.withAlphaComponent(0.5)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.addSubview(material)
        material.snp.makeConstraints { $0.edges.equalToSuperview() }

        let artwork = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 12
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
            $0.snp.makeConstraints { $0.size.equalTo(64) }
        }
        titleLabel.do {
            $0.text = PackageCenter.default.name(of: package)
            $0.font = .bodyEmphasized
            $0.textColor = .label
        }
        messageLabel.do {
            $0.font = .footnote
            $0.textColor = .label
        }
        countLabel.do {
            $0.font = .monospacedDigit(.footnote)
            $0.textColor = .secondaryLabel
        }
        for label in [titleLabel, messageLabel, countLabel] {
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }
        bar.progressTintColor = AlertControllerConfiguration.accentColor

        // a lone action is the accent one, as the library draws it; the
        // library does not export its button
        var accent = UIButton.Configuration.filled()
        accent.title = String(localized: "Cancel")
        accent.baseForegroundColor = AlertControllerConfiguration.accentForegroundColor
        accent.baseBackgroundColor = AlertControllerConfiguration.accentColor
        accent.background.cornerRadius = 12
        accent.cornerStyle = .fixed
        accent.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        accent.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var outgoing = $0
            outgoing.font = .bodyEmphasized
            return outgoing
        }
        cancelButton.configuration = accent
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            work?.cancel()
            Task { await self.close() }
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            artwork, titleLabel, messageLabel, bar, countLabel, cancelButton,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 12
            $0.setCustomSpacing(16, after: artwork)
            $0.setCustomSpacing(16, after: messageLabel)
            $0.setCustomSpacing(8, after: bar)
            $0.setCustomSpacing(16, after: countLabel)
        }
        view.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        for child in stack.arrangedSubviews where child !== artwork {
            child.snp.makeConstraints { $0.width.equalToSuperview() }
        }
    }
}
