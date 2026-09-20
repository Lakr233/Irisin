//
//  PackageUpdateTableCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import SDWebImage
import SPIndicator
import UIKit

class PackageUpdateTableCell: UITableViewCell {
    let originalCell = PackageListRow()
    let button = UIButton()
    var padding: CGFloat = 0 {
        didSet {
            updateSnapKitConstraints()
        }
    }

    var updateCandidate: Package?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        button.setImage(.fluent(.arrowUpCircle24Filled), for: .normal)
        button.addTarget(self, action: #selector(sendUpdate), for: .touchUpInside)
        contentView.addSubview(button)
        contentView.addSubview(originalCell)
        updateSnapKitConstraints()
        backgroundColor = .clear
    }

    func updateSnapKitConstraints() {
        originalCell.horizontalPadding = 0
        button.snp.remakeConstraints { x in
            x.centerY.equalToSuperview()
            x.width.equalTo(33)
            x.height.equalTo(33)
            x.trailing.equalToSuperview().offset(-padding)
        }
        originalCell.snp.remakeConstraints { x in
            x.leading.equalToSuperview().offset(padding)
            x.trailing.equalTo(button.snp.leading).offset(-5)
            x.top.equalToSuperview()
            x.bottom.equalToSuperview()
        }
        layoutSubviews()
    }

    @objc
    func sendUpdate() {
        guard let package = updateCandidate, let host = parentViewController else { return }
        Task { await PackageMenu.enqueue([.install(package)], from: host) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        originalCell.prepareForReuse()
        updateCandidate = nil
    }

    func loadValue(package: Package) {
        originalCell.loadValue(package: package)
    }

    func overrideIndicator(with icon: UIImage, and color: UIColor) {
        originalCell.overrideIndicator(with: icon, and: color)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func loadUpdateValue(package: Package) {
        guard let installed = originalCell.represent else {
            return
        }

        updateCandidate = package

        let unknownVersion = String(localized: "Unknown")
        let installedVersion = installed.latestVersion ?? unknownVersion
        let newVersion = package.latestVersion ?? unknownVersion
        let newVersionString = "\(installedVersion) → \(newVersion)"
        originalCell.subtitle.text = newVersionString
        originalCell.subtitle.highlight(text: newVersion, font: nil, color: .versionHighlight)

        let newPackageDescription = PackageCenter.default.description(of: package)
        let newRepoName = RepositoryCenter
            .default
            .obtainImmutableRepository(withUrl: package.repoRef ?? URL(fileURLWithPath: ""))?
            .nickName ?? String(localized: "Unknown")
        let newDescription = "[\(newRepoName)] \(newPackageDescription)"
        originalCell.describe.text = newDescription
    }
}
