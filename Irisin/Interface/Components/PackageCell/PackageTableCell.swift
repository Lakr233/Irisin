//
//  PackageTableCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/18.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

class PackageTableCell: UITableViewCell {
    let originalCell = PackageCell()

    func prepareForNewValue() {
        originalCell.prepareForNewValue()
    }

    func loadValue(package: Package) {
        originalCell.loadValue(package: package)
    }

    func overrideIndicator(with icon: UIImage, and color: UIColor) {
        originalCell.overrideIndicator(with: icon, and: color)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(originalCell)
        originalCell.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
