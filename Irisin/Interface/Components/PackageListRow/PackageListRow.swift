//
//  PackageListRow.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/18.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import SDWebImage
import Then
import UIKit

class PackageListRow: UIView {
    /// Between the icon and the text, and between the icon and whatever a
    /// list puts before it: the Installed page's selection mark.
    static let iconSpacing: CGFloat = 8

    var horizontalPadding: CGFloat = 0 {
        didSet {
            updatePadding()
        }
    }

    let contentView = UIView()

    let avatar = UIImageView().then {
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
    }

    let indicator = UIImageView().then {
        $0.backgroundColor = .clear
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
    }

    let title = UILabel().then {
        $0.font = .bodyEmphasized
        $0.textColor = .textTitle
    }

    let subtitle = UILabel().then {
        $0.font = .footnote
        $0.lineBreakMode = .byTruncatingTail
        $0.textColor = .textSubtitle
    }

    let describe = UILabel().then {
        $0.font = .caption
        $0.lineBreakMode = .byTruncatingTail
        $0.textColor = .textSubtitle
        $0.numberOfLines = 1
    }

    private let text = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 1
    }

    /// A slot at the trailing edge for whatever a row wants beside its
    /// text; empty, it has no width and the text runs to the edge.
    let accessory = UIView()

    /// The package the row is drawn for, and with that what decides whether
    /// a `loadValue` has anything to draw: nil once the row is reused.
    private(set) var represent: Package?
    /// what `represent` was last drawn from: itself, or its install origin
    private var described: Package?

    private var subscriptions = Set<AnyCancellable>()

    /// The installed version the badge was drawn for, nil when it shows none.
    private var badgedVersion: String?

    private var installedVersion: String? {
        represent.flatMap { PackageCenter.default.obtainPackageInstallationInfo(with: $0.identity)?.version }
    }

    /// The row's height at the current text size, for the collection grids
    /// that lay rows out by number. A table row sizes itself from the same
    /// constraints and needs no number. Measured once per text size, which
    /// is the app's and not a view's: a layout asks for every section.
    static var rowHeight: CGFloat {
        let category = UIApplication.shared.preferredContentSizeCategory
        if let known = heights[category] {
            return known
        }
        let cell = PackageListRow()
        cell.title.text = "X"
        cell.subtitle.text = "X"
        cell.describe.text = "X"
        let height = cell.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        heights[category] = height
        return height
    }

    private static var heights: [UIContentSizeCategory: CGFloat] = [:]

    init() {
        super.init(frame: CGRect())

        let dragInteraction = UIDragInteraction(delegate: self)
        addInteraction(dragInteraction)

        addSubview(contentView)
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        text.addArrangedSubview(title)
        text.addArrangedSubview(subtitle)
        text.addArrangedSubview(describe)
        contentView.addSubview(avatar)
        contentView.addSubview(indicator)
        contentView.addSubview(text)
        contentView.addSubview(accessory)

        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // the row is one stop, its lines read together: the icon and the
        // badge are drawn from what the lines already say
        isAccessibilityElement = true
        accessibilityTraits = .button

        avatar.snp.makeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            x.leading.equalTo(contentView.snp.leading).offset(4 + horizontalPadding)
            x.height.equalTo(33)
            x.width.equalTo(33)
        }

        indicator.snp.makeConstraints { x in
            x.centerX.equalTo(avatar.snp.right).offset(-4)
            x.centerY.equalTo(avatar.snp.bottom).offset(-4)
            x.height.equalTo(16)
            x.width.equalTo(16)
        }

        // The row is as tall as its three lines plus a margin; the grids
        // hand that same height back, so the margin yields rather than
        // fight a point of rounding.
        accessory.snp.makeConstraints { x in
            x.trailing.equalToSuperview().offset(-10 - horizontalPadding)
            x.centerY.equalTo(contentView.snp.centerY)
            // nothing inside: no width, above the text's hugging so the
            // layout is not ambiguous; a subview pinned to the edges wins
            x.width.height.equalTo(0).priority(.high)
        }
        text.snp.makeConstraints { x in
            x.leading.equalTo(avatar.snp.trailing).offset(Self.iconSpacing)
            x.trailing.equalTo(accessory.snp.leading)
            x.centerY.equalTo(contentView.snp.centerY)
            x.top.greaterThanOrEqualToSuperview().offset(6).priority(.high)
        }

        // Whichever list holds the row, an install or a removal redraws the
        // badge of the rows whose installed version moved, and only those.
        NotificationCenter.default.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _ in
                guard let self, represent != nil else { return false }
                return installedVersion != badgedVersion
            }
            .sink { [weak self] _ in self?.updateIndicator() }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// The row is leaving the screen for the reuse pool: nothing it shows
    /// is the next package's, its icon least of all.
    func prepareForReuse() {
        represent = nil
        described = nil
        overrideIcon = nil
        avatar.showIcon(nil)
        clearText()
        clearIndicator()
    }

    private func clearText() {
        // a label keeps the attributes of its last attributed text through
        // a later `text`: a removal's strikethrough would outlive the row
        for label in [title, subtitle, describe] {
            label.attributedText = nil
        }
        title.textColor = .textTitle
        subtitle.textColor = .textSubtitle
        describe.textColor = .textSubtitle
        updateAccessibilityLabel()
    }

    /// What the row reads as: its three lines joined, the way the Installed
    /// page's cell joins them while the list is edited. A list that writes
    /// the lines itself says so afterwards.
    func updateAccessibilityLabel() {
        accessibilityLabel = [title, subtitle, describe]
            .compactMap(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    func clearIndicator() {
        indicator.image = nil
        indicator.backgroundColor = .clear
    }

    func updatePadding() {
        avatar.snp.updateConstraints { x in
            x.leading.equalTo(contentView.snp.leading).offset(4 + horizontalPadding)
        }
        accessory.snp.updateConstraints { x in
            x.trailing.equalToSuperview().offset(-10 - horizontalPadding)
        }
        contentView.setNeedsLayout()
    }

    /// Draws `package`. A list reconfigures every row that survived a
    /// reload, and a `Package` is equal only when all of it is: the row that
    /// already shows this one has nothing to redraw but the badge, which is
    /// the one thing here that lives outside the package.
    ///
    /// A dpkg row is drawn as its install origin describes it: the icon and
    /// the name are the repository's to give, and the control file rarely
    /// has either. `represent` stays the row the list handed over.
    func loadValue(package row: Package) {
        let package = PackageCenter.default.obtainDescription(of: row)
        guard row != represent || package != described else {
            updateIndicator()
            return
        }
        represent = row
        described = package
        clearText()

        avatar.showIcon(of: package)

        if package.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false {
            title.textColor = .paidPackage
        } else {
            title.textColor = .textTitle
        }
        title.text = PackageCenter.default.name(of: package)

        subtitle.text = package.latestVersion
        describe.text = PackageCenter.default.description(of: package)
        updateAccessibilityLabel()

        updateIndicator()
    }

    /// What the list wants in the corner regardless of the installed record:
    /// the Updates screen's arrow. Reapplied after every repaint.
    private var overrideIcon: (image: UIImage, color: UIColor)?

    func updateIndicator() {
        clearIndicator()
        defer {
            if let overrideIcon {
                indicator.tintColor = overrideIcon.color
                indicator.image = overrideIcon.image
            }
        }
        badgedVersion = installedVersion
        // a build this bootstrap cannot install, even through an adapter,
        // is neither an update nor the installed version: no badge
        if let represent, represent.isSupportedOnDevice {
            if let badgedVersion {
                indicator.backgroundColor = .versionBadgeBacking
                // against the versions that may be an update, as the Updates
                // page judges them
                if let currentCellVersion = represent.version(
                    comparedWith: badgedVersion,
                    accepted: PackageCenter.default.index.updateArchitectures
                ) {
                    let compare = Package.compareVersion(currentCellVersion, b: badgedVersion)
                    switch compare {
                    case .aIsBiggerThenB:
                        indicator.tintColor = .updateAvailable
                        indicator.image = .fluent(.arrowUpCircle24Filled)
                    case .aIsEqualToB:
                        indicator.tintColor = .upToDate
                        indicator.image = .fluent(.checkmarkCircle24Filled)
                    case .aIsSmallerThenB:
                        indicator.tintColor = .versionOlder
                        indicator.image = .fluent(.arrowUpCircle24Filled)
                            .sd_flippedImage(withHorizontal: false, vertical: true)
                    case .invalidParameter:
                        indicator.tintColor = .versionInvalid
                        indicator.image = .fluent(.errorCircle24Filled)
                    }
                }
            }
        }
    }

    func overrideIndicator(with icon: UIImage, and color: UIColor) {
        overrideIcon = (icon, color)
        indicator.tintColor = color
        indicator.image = icon
    }

    /// Back to the installed record's own badge: a row that is reconfigured
    /// is not reused, and would keep an arrow its package no longer has.
    func clearOverrideIndicator() {
        guard overrideIcon != nil else { return }
        overrideIcon = nil
        updateIndicator()
    }
}

extension NSUserActivity {
    /// A package dragged out of a list; `userInfo["attach"]` carries it.
    nonisolated static let dropPackageActivityType = "wiki.qaq.irisin.drop.package"
}

extension PackageListRow: UIDragInteractionDelegate {
    func dragInteraction(_: UIDragInteraction, itemsForBeginning _: UIDragSession) -> [UIDragItem] {
        guard let package = represent else { return [] }

        let provider = NSItemProvider(object: captureDragImage())
        let dragItem = UIDragItem(itemProvider: provider)

        if let data = package.propertyListEncoded() {
            let userActivity = NSUserActivity(activityType: NSUserActivity.dropPackageActivityType)
            userActivity.title = NSUserActivity.dropPackageActivityType
            userActivity.userInfo = ["attach": data]
            provider.registerObject(userActivity, visibility: .all)
        }

        return [dragItem]
    }

    private func captureDragImage() -> UIImage {
        UIGraphicsBeginImageContextWithOptions(bounds.size, isOpaque, 0.0)
        defer { UIGraphicsEndImageContext() }
        if let context = UIGraphicsGetCurrentContext() {
            layer.render(in: context)
            if let image = UIGraphicsGetImageFromCurrentImageContext() {
                return image
            }
        }
        return UIImage.fluent(.extension24Filled)
    }
}
