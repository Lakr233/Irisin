//
//  SearchCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/13.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Then
import UIKit

class SearchCell: UITableViewCell {
    let image = UIImageView().then {
        $0.image = UIImage.fluent(.bookNumber24Filled)
        $0.layer.cornerRadius = 8
        $0.tintColor = .buttonNormal
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
    }

    let title = UILabel().then {
        $0.font = .bodyEmphasized
        $0.clipsToBounds = false
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
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .gray

        let text = UIStackView(arrangedSubviews: [title, subtitle, describe]).then {
            $0.axis = .vertical
            $0.spacing = 1
        }
        contentView.addSubview(image)
        contentView.addSubview(text)

        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // one stop a row, its lines read together; what it is, and whether
        // it opens anything, is said by whichever row it is drawn as
        isAccessibilityElement = true

        image.snp.makeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            // the dashboard's edge, as on every package list
            x.leading.equalTo(contentView.snp.leading).offset(20)
            x.height.equalTo(33)
            x.width.equalTo(33)
        }

        text.snp.makeConstraints { x in
            x.leading.equalTo(image.snp.trailing).offset(8)
            x.trailing.equalToSuperview().offset(-10)
            x.top.bottom.equalToSuperview().inset(6)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        image.showIcon(nil)
    }

    /// What every row starts from. The picture is not part of it: each row
    /// below sets its own, and a row redrawn in place keeps the one it has
    /// until then.
    private func clearText() {
        title.text = ""
        title.textColor = .textTitle
        subtitle.text = ""
        describe.attributedText = nil
        describe.text = ""
        describe.textColor = .textSubtitle
    }

    /// The row's three lines joined: what a list reads at this stop.
    private func updateAccessibilityLabel() {
        accessibilityLabel = [title, subtitle, describe]
            .compactMap(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    func makeEmptyHinter() {
        clearText()
        image.showIcon(.fluent(.documentNone24Regular))
        title.text = String(localized: "No results found")
        subtitle.text = String(localized: "Try a different search or refresh your repositories.")
        describe.text = ""
        // nothing to open: the row is what it says
        accessibilityTraits = .staticText
        updateAccessibilityLabel()
    }

    func insertValue(with result: SearchResult) {
        clearText()
        switch result.associatedValue {
        // MARK: - AUTHOR

        case let .author(name):
            title.text = name
            subtitle.text = String(localized: "Packages by this author")
            image.showIcon(.fluent(.peopleSearch24Regular))

        // MARK: - INSTALLED

        case let .installed(package):
            insertPackageValue(package)

        // MARK: - PACKAGE

        case let .package(identity, repository):
            guard let package = PackageCenter.default.obtainPackage(with: identity, in: repository) else {
                // the index still remembers a row the repository no longer has
                image.showIcon(.fluent(.documentNone24Regular))
                title.text = identity
                subtitle.text = String(localized: "No longer available in this repository")
                accessibilityTraits = .button
                updateAccessibilityLabel()
                return
            }
            insertPackageValue(package)

        // MARK: - REPO

        case let .repository(url):
            let repo = RepositoryCenter
                .default
                .obtainImmutableRepository(withUrl: url)
            title.text = repo?.nickName
            subtitle.text = url.absoluteString
            image.showIcon(repo.flatMap { UIImage(data: $0.avatar) } ?? .fluent(.bookCompass24Filled))
        }

        // MARK: - SEARCH HIGHLIGHT

        let description = result
            .searchText
            .components(separatedBy: "\n")
            .filter { $0.contains(result.underKey) }
            .first
        describe.text = description
        describe.limitedLeadingHighlight(text: result.underKey, color: .buttonNormal)

        // every result opens a page of its own
        accessibilityTraits = .button
        updateAccessibilityLabel()
    }

    private func insertPackageValue(_ package: Package) {
        if package.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false {
            title.textColor = .paidPackage
        }
        title.text = PackageCenter.default.name(of: package)
        let description = PackageCenter.default.description(of: package)
        if let repoUrl = package.repoRef,
           let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: repoUrl)
        {
            subtitle.text = "[\(repo.nickName)] \(description)"
        } else {
            subtitle.text = description
        }
        image.showIcon(of: package)
    }
}
