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
/// bottom a step below a text's own hugging, free to outgrow the row or
/// fall short of it, and the cell says so (`onHeightMismatch`) for the page
/// to have its rows measured again. A pin any stronger wins against the
/// text instead: a markdown that learns its height at its first layout,
/// after the row was measured, is squeezed into the row and nobody hears.
final class PackageRowCell: UITableViewCell {
    /// Called when the view inside is no longer the height the row was
    /// measured for, with the height the row would have to be.
    var onHeightMismatch: ((CGFloat) -> Void)?

    private let host = HostView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .plainBackground
        contentView.addSubview(host)
        host.snp.makeConstraints { x in x.edges.equalToSuperview() }
        host.onHeightMismatch = { [weak self] height in self?.onHeightMismatch?(height) }
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
            x.bottom.equalToSuperview().offset(-insets.bottom).priority(UILayoutPriority.defaultLow.rawValue - 1)
        }
    }

    /// The height the row would have to be for the view inside, while it
    /// is not that height; nil when the view fits.
    var heightMismatch: CGFloat? {
        host.mismatch
    }

    private final class HostView: UIView {
        var onHeightMismatch: ((CGFloat) -> Void)?
        var bottomInset: CGFloat = 0

        var mismatch: CGFloat? {
            guard let hosted = subviews.first, bounds.height > 0 else { return nil }
            let wanted = hosted.frame.maxY + bottomInset
            return abs(wanted - bounds.height) > 1 ? wanted : nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let wanted = mismatch {
                onHeightMismatch?(wanted)
            }
        }
    }
}
