//
//  ListContentCell.swift
//  Irisin
//

import UIKit

/// A table row drawn by a content configuration, which starts clean every
/// time it is reused. A label keeps the attributes of its last attributed
/// text through a later plain `text`, and a list content view keeps its
/// label: a removal's strikethrough would come back on the next row to take
/// the cell. Dropping the configuration drops the view with it.
final class ListContentCell: UITableViewCell {
    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
    }
}
