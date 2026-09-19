//
//  PackageRowCell.swift
//  Irisin
//

import SnapKit
import UIKit

/// A row of the package page: a cell around a view the page owns (the
/// photo, the banner, the depiction), which outlives the cell and may be
/// exchanged for another under it.
///
/// A depiction is Auto Layout throughout and changes its own height (a tab,
/// a picture that arrives) without telling anyone. A scroll view followed;
/// a table has measured the row already. So the view is pinned at the
/// bottom a step below required, free to outgrow the row or fall short of
/// it, and the cell says so (`onHeightMismatch`) for the page to have its
/// rows measured again.
final class PackageRowCell: UITableViewCell {
    /// Called when the view inside is no longer the height the row was
    /// measured for.
    var onHeightMismatch: (() -> Void)?

    private let host = HostView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .plainBackground
        contentView.addSubview(host)
        host.snp.makeConstraints { x in x.edges.equalToSuperview() }
        host.onHeightMismatch = { [weak self] in self?.onHeightMismatch?() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// Puts `view` in the row, in place of whatever was there.
    func host(_ view: UIView, insets: UIEdgeInsets = .zero) {
        host.bottomInset = insets.bottom
        guard view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(view)
        // made, never remade: the photo brings a height of its own, and
        // leaving the last row already dropped what tied the view to it
        view.snp.makeConstraints { x in
            x.top.equalToSuperview().offset(insets.top)
            x.leading.equalToSuperview().offset(insets.left)
            x.trailing.equalToSuperview().offset(-insets.right)
            x.bottom.equalToSuperview().offset(-insets.bottom).priority(999)
        }
    }

    private final class HostView: UIView {
        var onHeightMismatch: (() -> Void)?
        var bottomInset: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let hosted = subviews.first, bounds.height > 0 else { return }
            if abs(hosted.frame.maxY + bottomInset - bounds.height) > 1 {
                onHeightMismatch?()
            }
        }
    }
}
