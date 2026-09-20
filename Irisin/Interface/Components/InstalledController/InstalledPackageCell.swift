//
//  InstalledPackageCell.swift
//  Irisin
//

import AptRepository
import SnapKit
import Then
import UIKit

/// A row of the Installed page: `PackageListRow` in a list cell, which is what
/// slides aside for a swipe. It draws no ground of its own, selected or not.
///
/// While the list is edited the row shows a selection mark of its own. The
/// system's multiselect accessory brings its margins and a reserved width
/// with it; this one starts on the row's leading edge, where the icon is
/// when nothing is edited and the date above the row begins, and stands as
/// far from the icon as the icon does from the text.
final class InstalledPackageCell: UICollectionViewListCell {
    let originalCell = PackageListRow()
    private let selectionMark = SelectionMarkView()

    /// A row is as tall as `PackageListRow` at the text size in use, which is
    /// the app's and not a view's: `PackageListRow` takes its fonts from there.
    /// Measured once per text size: a list section asks every row.
    private static var heights: [UIContentSizeCategory: CGFloat] = [:]

    static var rowHeight: CGFloat {
        let category = UIApplication.shared.preferredContentSizeCategory
        if let known = heights[category] {
            return known
        }
        let height = max(PackageListRow.rowHeight, PackageListRow.minimumSize.height)
        heights[category] = height
        return height
    }

    /// How far the row moves in to make room for the mark.
    private static let editingIndent = SelectionMarkView.side + PackageListRow.iconSpacing

    private var leading: Constraint?
    private var showsMark = false
    /// A row that comes on screen in an edited list is there already
    /// indented; only a row that saw the editing begin slides.
    private var hasConfigured = false

    override init(frame _: CGRect) {
        super.init(frame: CGRect())
        backgroundConfiguration = .clear()
        // the section has the page's inset already
        preservesSuperviewLayoutMargins = false
        directionalLayoutMargins = .zero
        contentView.preservesSuperviewLayoutMargins = false
        contentView.directionalLayoutMargins = .zero

        contentView.addSubview(selectionMark)
        contentView.addSubview(originalCell)
        selectionMark.alpha = 0
        selectionMark.snp.makeConstraints { x in
            x.leading.equalToSuperview()
            x.centerY.equalToSuperview()
            x.width.height.equalTo(SelectionMarkView.side)
        }
        originalCell.snp.makeConstraints { x in
            x.top.bottom.trailing.equalToSuperview()
            leading = x.leading.equalToSuperview().constraint
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        originalCell.prepareForReuse()
        hasConfigured = false
    }

    /// The ground stays clear through every state: the page's own shows. The
    /// mark comes and goes with the list's editing, and says whether the row
    /// is one of the selected.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = .clear()
        selectionMark.isOn = state.isEditing && state.isSelected
        // edited, the row is one element that says whether it is selected;
        // otherwise its labels are read as they are
        isAccessibilityElement = state.isEditing
        accessibilityLabel = [originalCell.title, originalCell.subtitle, originalCell.describe]
            .compactMap(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        accessibilityTraits = state.isEditing && state.isSelected ? [.button, .selected] : .button
        let animates = hasConfigured && window != nil
        hasConfigured = true
        guard state.isEditing != showsMark else { return }
        showsMark = state.isEditing
        leading?.update(offset: showsMark ? Self.editingIndent : 0)
        let change = { [self] in
            selectionMark.alpha = showsMark ? 1 : 0
            contentView.layoutIfNeeded()
        }
        if animates {
            UIView.animate(withDuration: 0.25, delay: 0, options: .beginFromCurrentState, animations: change)
        } else {
            change()
        }
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        layoutAttributes.size.height = Self.rowHeight
        return layoutAttributes
    }
}

/// The circle a row is ticked in. Drawn, not a symbol: a symbol keeps a
/// margin of its own inside its frame, and this one's edge is the row's.
private final class SelectionMarkView: UIView {
    /// The title size of the type ramp: the system's own mark is as large.
    static let side = TypeSize.title.rawValue

    private let tick = UIImageView(image: UIImage(
        systemName: "checkmark",
        // as fixed as the circle around it: a tick that grew with the text
        // size would leave it
        withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)
    )).then {
        $0.tintColor = .onAccent
        $0.contentMode = .center
    }

    var isOn = false {
        didSet { draw() }
    }

    init() {
        super.init(frame: CGRect())
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.side / 2
        addSubview(tick)
        tick.snp.makeConstraints { x in
            x.center.equalToSuperview()
        }
        draw()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// A layer's colour is resolved once: the other appearance asks again.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        draw()
    }

    private func draw() {
        tick.isHidden = !isOn
        backgroundColor = isOn ? .buttonNormal : .clear
        layer.borderWidth = isOn ? 0 : 1.5
        layer.borderColor = UIColor.selectionMarkIdle.resolvedColor(with: traitCollection).cgColor
    }
}
