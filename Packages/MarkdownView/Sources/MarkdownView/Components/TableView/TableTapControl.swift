//
//  TableTapControl.swift
//  MarkdownView
//

import Foundation
import UIKit

/// A tappable region of a table, such as a sortable header, whose hit area can be larger
/// than what it draws.
///
/// The glyph sits in `glyphFrame`, in the control's own coordinates, so
/// the table decides where it goes.
final class TableTapControl: UIControl {
    var handler: (() -> Void)?

    private let imageView = UIImageView()

    var glyphFrame: CGRect = .zero {
        // Set on every layout pass, so an unchanged one is left alone.
        didSet {
            guard oldValue != glyphFrame else { return }
            imageView.frame = glyphFrame
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .center
        imageView.tintColor = .label
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Draws the SF Symbol `name`, or nothing for nil.
    func setSymbol(_ name: String?) {
        guard let name else {
            imageView.image = nil
            return
        }
        let configuration = UIImage.SymbolConfiguration(
            pointSize: TableHeaderAccessory.glyphSize - 2,
            weight: .medium
        )
        imageView.image = UIImage(systemName: name, withConfiguration: configuration)
    }

    var symbolImage: UIImage? {
        imageView.image
    }

    func setAccessibleTitle(_ title: String?) {
        accessibilityLabel = title
    }

    @objc private func fire() {
        handler?()
    }

    /// What a tap does, without a touch; for accessibility and tests.
    func performTap() {
        handler?()
    }

    override func accessibilityActivate() -> Bool {
        handler?()
        return handler != nil
    }
}
