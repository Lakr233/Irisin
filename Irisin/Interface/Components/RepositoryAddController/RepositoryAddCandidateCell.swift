//
//  RepositoryAddCandidateCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import SnapKit
import Then
import UIKit

/// One address on the add sheet. Starts as the host name over the URL with
/// a spinner where the icon goes, and becomes the repository's own name and
/// icon once its Release file has been read.
final class RepositoryAddCandidateCell: UITableViewCell {
    enum Preview {
        case loading
        case loaded(RepositoryPreview)
        /// The host did not answer with a Release file. It can still be
        /// added; the refresh will say what is wrong.
        case failed
    }

    private let icon = UIImageView().then {
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFill
        $0.backgroundColor = .tertiarySystemFill
    }

    private let spinner = UIActivityIndicatorView(style: .medium).then {
        $0.hidesWhenStopped = true
    }

    private let title = UILabel().then {
        $0.font = .bodyEmphasized
        $0.textColor = .label
    }

    private let subtitle = UILabel().then {
        $0.font = .footnote
        $0.textColor = .secondaryLabel
        $0.lineBreakMode = .byTruncatingMiddle
    }

    private let button = UIButton(configuration: .tinted())
    private let text = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 2
    }

    var onAdd: (() -> Void)?

    /// The row under the field only reports; it has no Add of its own.
    var showsButton = true {
        didSet {
            guard showsButton != oldValue else { return }
            button.isHidden = !showsButton
            text.snp.remakeConstraints { x in
                x.leading.equalTo(icon.snp.trailing).offset(12)
                x.centerY.equalTo(icon)
                x.top.greaterThanOrEqualToSuperview().inset(10)
                if showsButton {
                    x.trailing.equalTo(button.snp.leading).offset(-12)
                } else {
                    x.trailing.equalTo(contentView.layoutMarginsGuide)
                }
            }
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        text.addArrangedSubview(title)
        text.addArrangedSubview(subtitle)
        contentView.addSubview(icon)
        contentView.addSubview(spinner)
        contentView.addSubview(text)
        contentView.addSubview(button)

        // Tall enough for the icon or the two lines, whichever needs more.
        icon.snp.makeConstraints { x in
            x.leading.equalTo(contentView.layoutMarginsGuide)
            x.centerY.equalToSuperview()
            x.top.greaterThanOrEqualToSuperview().inset(12)
            x.size.equalTo(40)
        }
        spinner.snp.makeConstraints { x in
            x.center.equalTo(icon)
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.snp.makeConstraints { x in
            x.trailing.equalTo(contentView.layoutMarginsGuide)
            x.centerY.equalTo(icon)
            x.width.greaterThanOrEqualTo(56)
        }
        text.snp.makeConstraints { x in
            x.leading.equalTo(icon.snp.trailing).offset(12)
            x.trailing.equalTo(button.snp.leading).offset(-12)
            x.centerY.equalTo(icon)
            x.top.greaterThanOrEqualToSuperview().inset(10)
        }
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// `line` is the source as typed: an address, or a sources.list line.
    func configure(line: String, preview: Preview, added: Bool) {
        subtitle.text = line
        switch preview {
        case .loading:
            icon.image = nil
            spinner.startAnimating()
            title.text = RepositorySource(line: line)?.url.host ?? line
        case let .loaded(info):
            icon.image = info.avatar.flatMap(UIImage.init(data:)) ?? UIImage(named: "RepositoryTableCell.Missing")
            spinner.stopAnimating()
            title.text = info.name
        case .failed:
            // nothing answered, so there is no icon to show; the title says so
            icon.image = nil
            spinner.stopAnimating()
            title.text = String(localized: "Repository Unreachable")
        }

        var configuration: UIButton.Configuration = added ? .plain() : .tinted()
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .buttonNormal
        if added {
            configuration.image = UIImage(systemName: "checkmark.circle.fill")
        } else {
            configuration.title = String(localized: "Add")
        }
        // the checkmark carries no title of its own
        button.accessibilityLabel = added
            ? String(localized: "Already Added")
            : String(localized: "Add")
        button.configuration = configuration
        button.isUserInteractionEnabled = !added
    }

    @objc
    private func tapped() {
        onAdd?()
    }
}
