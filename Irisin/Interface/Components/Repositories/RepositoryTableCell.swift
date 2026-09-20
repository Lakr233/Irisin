//
//  RepositoryTableCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/19.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import SnapKit
import UIKit

class RepositoryTableCell: UITableViewCell {
    let coordinatedCell = RepositoryRow()

    private let updateFill = RepositoryUpdateFill()

    /// Padding around the repository row.
    var contentInsets: UIEdgeInsets = .zero {
        didSet {
            coordinatedCell.snp.remakeConstraints { x in
                x.edges.equalToSuperview().inset(contentInsets)
            }
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // A selection style of none also stops the editing checkmark from
        // filling in; keep the style and blank the highlight instead.
        selectionStyle = .default
        selectedBackgroundView = UIView()
        multipleSelectionBackgroundView = UIView()
        backgroundColor = .clear
        contentView.addSubview(updateFill)
        contentView.addSubview(coordinatedCell)
        updateFill.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        coordinatedCell.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func setRepository(withUrl: URL) {
        coordinatedCell.setRepository(withUrl: withUrl)
        updateFill.url = withUrl
    }

    func setNoRepoAvailable() {
        coordinatedCell.setNoRepoAvailable()
        updateFill.url = nil
    }
}
