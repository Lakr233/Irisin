//
//  BlockquoteBarView.swift
//  MarkdownView
//
//  Created by Claude on 8/8/26.
//

import Foundation

/// Identifies the lines belonging to one blockquote.
///
/// Carried by ``NSAttributedString/Key/blockquoteGroup`` so a layout pass can
/// collect a quote's lines and give its bar a single frame spanning all of them.
final class BlockquoteGroup: Hashable {
    static func == (lhs: BlockquoteGroup, rhs: BlockquoteGroup) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// The vertical bar drawn beside a blockquote.
///
/// A view rather than a line drawing action: actions only run for the lines a
/// redraw touches, which leaves a bar spanning many lines painted in fragments.
final class BlockquoteBarView: UIView {
    static let width: CGFloat = 4

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.width / 2
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var theme: MarkdownTheme = .default

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
        applyThemeColor()
    }

    private func applyThemeColor() {
        let color = theme.colors.body.withAlphaComponent(0.1)
        backgroundColor = color
    }

    override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? {
        nil
    }
}
