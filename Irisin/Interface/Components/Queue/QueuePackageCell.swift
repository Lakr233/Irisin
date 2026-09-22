//
//  QueuePackageCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import GlyphixTextFx
import Then
import UIKit

/// A queue row that is also its own download bar: the change sheet's row,
/// with the accent tinting it from the leading edge as the package's bytes
/// arrive, the way a repository row shows its refresh, and fading once the
/// file is on disk. The trailing edge says where the download stands: a
/// spinner while it waits its turn, the percentage while it runs,
/// Downloaded once the file is here. Downloaded is a plain grey word on
/// purpose: the row is not installed until the bar button is tapped.
///
/// The row is the cell's content configuration, so the table aligns the
/// separator with the name; the fill lives in the background, which a
/// configuration never replaces.
final class QueuePackageCell: UITableViewCell {
    /// The cell's own ground with the fill over it, as the background's
    /// custom view.
    private let ground = UIView()

    private let progressFill = UIView().then {
        $0.backgroundColor = .buttonNormal.withAlphaComponent(0.1)
        $0.alpha = 0
    }

    private let status = UIView()

    private let spinner = UIActivityIndicatorView(style: .medium).then {
        $0.hidesWhenStopped = true
    }

    private let label = GlyphixTextLabel().then {
        $0.font = UIFont.footnote.monospacedDigitFont
        $0.textColor = .textSubtitle
        $0.textAlignment = .trailing
    }

    /// The disclosure of a row that opens its package. The status is the
    /// accessory view, so the cell draws the chevron itself, and keeps its
    /// column while a download runs: the percentage stays where it is when
    /// the chevron arrives.
    private let chevron = UIImageView(image: UIImage(
        systemName: "chevron.right",
        withConfiguration: UIImage.SymbolConfiguration(font: .type(.footnote, emphasized: true), scale: .small)
    )).then {
        $0.tintColor = .tertiaryLabel
        $0.contentMode = .right
    }

    private static let chevronWidth: CGFloat = 18

    /// Wide enough for the longest word the trailing edge says.
    private static let statusWidth: CGFloat = {
        let font = UIFont.footnote.monospacedDigitFont
        let words = [String(localized: "Downloaded"), String(localized: "Failed"), "99%"]
        let widest = words.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 8
    }()

    private var fraction: CGFloat = 0
    /// The row's package when the page downloads it. A removal or a local
    /// file has nothing to show at its trailing edge.
    private var download: Package?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        // the fill keeps to the card's rounded corners
        clipsToBounds = true
        // a state update would put the opaque colour back over the fill
        automaticallyUpdatesBackgroundConfiguration = false
        var background = defaultBackgroundConfiguration()
        ground.backgroundColor = background.resolvedBackgroundColor(for: tintColor)
        ground.addSubview(progressFill)
        background.backgroundColor = .clear
        background.customView = ground
        backgroundConfiguration = background

        // the word, then the chevron's column; a row with no download
        // narrows the status to the column alone
        status.frame = CGRect(x: 0, y: 0, width: Self.statusWidth + Self.chevronWidth, height: 24)
        status.addSubview(label)
        status.addSubview(spinner)
        status.addSubview(chevron)
        label.frame = CGRect(x: 0, y: 0, width: Self.statusWidth, height: 24)
        label.autoresizingMask = [.flexibleLeftMargin, .flexibleHeight]
        spinner.center = CGPoint(x: Self.statusWidth - spinner.bounds.midX, y: status.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin, .flexibleBottomMargin]
        chevron.frame = CGRect(x: Self.statusWidth, y: 0, width: Self.chevronWidth, height: 24)
        chevron.autoresizingMask = [.flexibleLeftMargin, .flexibleHeight]

        // One stop a row: the name and what is queued for it, with the
        // download's word as the row's value. The trailing edge holds no
        // control — a drawn word, a spinner and a chevron — and the page a
        // row opens is opened by the row itself, so the cell reads for all
        // of it.
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// The ground is the cell's own and no state update repaints it, so a
    /// press is shown here: the page a row opens may take a moment to come.
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        var state = configurationState
        state.isHighlighted = highlighted
        let color = defaultBackgroundConfiguration().updated(for: state).resolvedBackgroundColor(for: tintColor)
        UIView.animate(withDuration: animated ? 0.2 : 0) { self.ground.backgroundColor = color }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // the ground is laid out after this; it covers the cell
        progressFill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }

    /// Shows the row, and the download of `download` at its trailing edge.
    /// A row with no download says here whether it `opens`; one with a
    /// download opens once the file is here.
    func apply(_ configuration: UIListContentConfiguration, download: Package?, opens: Bool) {
        contentConfiguration = configuration
        self.download = download
        label.isHidden = download == nil
        chevron.isHidden = !opens
        status.frame.size.width = (download == nil ? 0 : Self.statusWidth) + Self.chevronWidth
        accessoryView = download == nil && !opens ? nil : status
        // the chevron is the only sign that the row opens, and the trailing
        // word is drawn text a reader never reaches
        accessibilityTraits = opens ? .button : .staticText
        // the name is drawn attributed for a removal, the lines under it
        // plain: whichever the configuration carries, read together
        accessibilityLabel = [configuration.attributedText?.string ?? configuration.text, configuration.secondaryText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        setNeedsLayout()
        label.disablesAnimations = true
        show("")
        label.disablesAnimations = false
        spinner.stopAnimating()
        set(fraction: 0, visible: false, animated: false)
        refreshProgress(animated: false)
    }

    /// Reads `Downloads` for the row's package: the spinner before
    /// its download starts, the bar and the percentage while it runs, a
    /// fade and Downloaded once it is complete.
    func refreshProgress(animated: Bool) {
        guard let download else { return }
        label.disablesAnimations = !animated
        defer { label.disablesAnimations = false }
        let status = Downloads.shared.status(for: download.obtainDownloadLink())
        chevron.isHidden = !(status?.completed == true && status?.errorDescription == nil)
        guard let status else {
            spinner.startAnimating()
            show("")
            return set(fraction: 0, visible: false, animated: animated)
        }
        spinner.stopAnimating()
        label.textColor = status.errorDescription == nil ? .textSubtitle : .operationFailed
        if status.errorDescription != nil {
            show(String(localized: "Failed"))
        } else if status.completed {
            show(String(localized: "Downloaded"))
        } else {
            // 1 to 99: the first byte is already progress, the last is not done
            show("\(min(max(Int(status.fractionCompleted * 100), 1), 99))%")
        }
        set(fraction: status.completed ? 1 : status.fractionCompleted, visible: !status.completed, animated: animated)
    }

    /// The poll that drives this comes four times a second, so only a
    /// change gets through.
    private func show(_ text: String) {
        accessibilityValue = text.isEmpty ? nil : text
        if label.text != text {
            label.text = text
        }
    }

    private func set(fraction: Double, visible: Bool, animated: Bool) {
        self.fraction = CGFloat(fraction)
        setNeedsLayout()
        let changes = {
            self.progressFill.alpha = visible ? 1 : 0
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animateProgress(changes)
        } else {
            changes()
        }
    }
}
