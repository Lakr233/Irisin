//
//  Created by ktiays on 2025/1/22.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext
import UIKit

@MainActor
enum CodeViewConfiguration {
    nonisolated static let barPadding: CGFloat = 8
    nonisolated static let codePadding: CGFloat = 8
    nonisolated static let codeLineSpacing: CGFloat = 4
    nonisolated static let lineNumberWidth: CGFloat = 40
    nonisolated static let lineNumberPadding: CGFloat = 8

    static func intrinsicHeight(
        for content: String,
        theme: MarkdownTheme = .default
    ) -> CGFloat {
        let numberOfRows = content.components(separatedBy: .newlines).count
        return intrinsicHeight(lineCount: numberOfRows, theme: theme)
    }

    static func intrinsicHeight(
        lineCount: Int,
        theme: MarkdownTheme = .default
    ) -> CGFloat {
        let font = theme.fonts.code
        let lineHeight = font.lineHeight
        let barHeight = lineHeight + barPadding * 2
        let codeHeight = lineHeight * CGFloat(lineCount)
            + codePadding * 2
            + codeLineSpacing * CGFloat(max(lineCount - 1, 0))
        return ceil(barHeight + codeHeight)
    }

    /// A code block's text: the code font and colour, with the line spacing
    /// the height above counts on. Nothing is highlighted.
    static func attributedCode(_ content: String, theme: MarkdownTheme) -> NSMutableAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = codeLineSpacing
        return NSMutableAttributedString(
            string: content,
            attributes: [
                .font: theme.fonts.code,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: theme.colors.code,
            ]
        )
    }
}

extension CodeView {
    func configureSubviews() {
        setupViewAppearance()
        setupBarView()
        setupButtons()
        setupScrollView()
        setupTextView()
        setupLineNumberView()
        applyBackgroundColors()
    }

    private func setupButtons() {
        setupPreviewButton()
        setupCopyButton()
        setupBarButton(expandButton, symbol: CodeView.expandSymbol, title: TableTitleText.expand, action: #selector(handleExpand(_:)))
    }

    func performLayout() {
        let labelSize = languageLabel.intrinsicContentSize
        let barHeight = max(languageLabel.lineHeight, labelSize.height) + CodeViewConfiguration.barPadding * 2

        layoutBarView(barHeight: barHeight, labelSize: labelSize)
        layoutButtons()
        layoutLineNumberView(barHeight: barHeight)
        layoutScrollViewAndTextView(barHeight: barHeight)
    }

    /// Lays the bar's buttons out from the trailing edge: Expand, Copy, then
    /// Preview when there is a handler, then the host's actions.
    private func layoutButtons() {
        let buttonSize = CGSize(width: TableTitleBar.buttonWidth, height: 44)
        previewButton.isHidden = previewAction == nil
        var trailing = barView.bounds.width - 4
        for button in barButtons where !button.isHidden {
            trailing -= buttonSize.width
            button.applyFrame(CGRect(
                x: trailing,
                y: (barView.bounds.height - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            ))
        }
    }

    private func layoutBarView(barHeight: CGFloat, labelSize: CGSize) {
        barView.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: barHeight))
        languageLabel.frame = CGRect(
            origin: CGPoint(x: CodeViewConfiguration.barPadding, y: CodeViewConfiguration.barPadding),
            size: labelSize
        )
    }

    private func layoutLineNumberView(barHeight: CGFloat) {
        let lineNumberSize = lineNumberView.intrinsicContentSize
        lineNumberView.frame = CGRect(
            x: 0,
            y: barHeight,
            width: lineNumberSize.width,
            height: bounds.height - barHeight
        )
    }

    private func layoutScrollViewAndTextView(barHeight: CGFloat) {
        let textContentSize = textView.intrinsicContentSize
        let lineNumberWidth = lineNumberView.intrinsicContentSize.width

        scrollView.frame = CGRect(
            x: lineNumberWidth,
            y: barHeight,
            width: bounds.width - lineNumberWidth,
            height: bounds.height - barHeight
        )

        let textOrigin = CGPoint(x: CodeViewConfiguration.codePadding, y: CodeViewConfiguration.codePadding)
        textView.frame = CGRect(
            x: textOrigin.x,
            y: textOrigin.y,
            width: max(scrollView.bounds.width - CodeViewConfiguration.codePadding * 2, textContentSize.width),
            height: textContentSize.height
        )

        scrollView.contentSize = CGSize(
            width: textView.frame.width + CodeViewConfiguration.codePadding * 2,
            height: 0
        )
    }
}

private extension CodeView {
    func setupViewAppearance() {
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        // Not clipped, so a selection's handles can reach past the code;
        // the bar rounds its own corners instead.
        clipsToBounds = false
    }

    func setupBarView() {
        barView.layer.cornerRadius = layer.cornerRadius
        barView.layer.cornerCurve = .continuous
        barView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(barView)
        barView.addSubview(languageLabel)
    }

    func setupPreviewButton() {
        let previewImage = UIImage(
            systemName: "eye",
            withConfiguration: UIImage.SymbolConfiguration(scale: .small)
        )
        previewButton.setImage(previewImage, for: .normal)
        previewButton.tintColor = .label
        previewButton.addTarget(self, action: #selector(handlePreview(_:)), for: .touchUpInside)
        barView.addSubview(previewButton)
    }

    func setupCopyButton() {
        setupBarButton(copyButton, symbol: CodeView.copySymbol, title: TableTitleText.copy, action: #selector(handleCopy(_:)))
    }

    func setupBarButton(_ button: UIButton, symbol: String, title: String, action: Selector) {
        let image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(scale: .small)
        )
        button.setImage(image, for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        barView.addSubview(button)
    }

    func setupScrollView() {
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.blankLeadingWidth = CodeViewConfiguration.codePadding
        scrollView.blankTrailingWidth = CodeViewConfiguration.codePadding
        addSubview(scrollView)
    }

    func setupTextView() {
        textView.backgroundColor = .clear
        textView.preferredMaxLayoutWidth = .greatestFiniteMagnitude
        textView.isSelectable = true
        textView.selectionBackgroundColor = theme.colors.selectionBackground
        scrollView.addSubview(textView)
    }

    func setupLineNumberView() {
        lineNumberView.backgroundColor = .clear
        // Under the code, so a selection's handles draw over the gutter.
        insertSubview(lineNumberView, belowSubview: scrollView)
        updateLineNumberView()
    }
}

extension CodeView {
    /// Paints the body and the bar in the theme's code block colours.
    func applyBackgroundColors() {
        backgroundColor = theme.colors.codeBlockBackground
        barView.backgroundColor = theme.colors.codeBlockBarBackground
    }
}
