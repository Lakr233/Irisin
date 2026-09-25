//
//  Created by ktiays on 2025/1/22.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext
import UIKit

final class CodeView: UIView {
    // MARK: - CONTENT

    private var needsTextRebuild = false

    var theme: MarkdownTheme = .default {
        didSet {
            languageLabel.font = theme.fonts.code
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            updateLineNumberView()
            if oldValue.fonts.code != theme.fonts.code || oldValue.colors.code != theme.colors.code {
                needsTextRebuild = true
            }
        }
    }

    var language: String = "" {
        didSet {
            languageLabel.text = language.isEmpty ? "</>" : language
        }
    }

    var content: String = "" {
        didSet {
            guard oldValue != content || needsTextRebuild else { return }
            needsTextRebuild = false
            cachedLineCount = max(content.components(separatedBy: .newlines).count, 1)
            textView.attributedText = CodeViewConfiguration.attributedCode(content, theme: theme)
            lineNumberView.updateForContent(content)
            updateLineNumberView()
        }
    }

    private var cachedLineCount: Int = 1

    // MARK: CONTENT -

    var previewAction: ((String?, NSAttributedString) -> Void)? {
        didSet {
            guard (oldValue == nil) != (previewAction == nil) else { return }
            setNeedsLayout()
        }
    }

    private let callerIdentifier = UUID()
    private var currentTaskIdentifier: UUID?

    lazy var barView: UIView = .init()
    lazy var scrollView: UIScrollView = .init()
    lazy var languageLabel: UILabel = .init()
    lazy var textView: TextLabelView = .init()
    lazy var copyButton: UIButton = .init()
    lazy var previewButton: UIButton = .init()
    lazy var lineNumberView: LineNumberView = .init()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        updateLineNumberView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func intrinsicHeight(for content: String, theme: MarkdownTheme = .default) -> CGFloat {
        CodeViewConfiguration.intrinsicHeight(for: content, theme: theme)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
        updateLineNumberView()
    }

    func interactionTarget(at point: CGPoint, event: UIEvent? = nil) -> UIView? {
        for button in [previewButton, copyButton] where !button.isHidden {
            let buttonPoint = button.convert(point, from: self)
            guard button.bounds.contains(buttonPoint) else { continue }
            return button.hitTest(buttonPoint, with: event) ?? button
        }

        let textPoint = textView.convert(point, from: self)
        if textView.bounds.contains(textPoint),
           let target = textView.hitTest(textPoint, with: event)
        {
            return target
        }

        let scrollPoint = scrollView.convert(point, from: self)
        if scrollView.bounds.contains(scrollPoint),
           scrollView.contentSize.width > scrollView.bounds.width + 1
        {
            return scrollView
        }

        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01,
              bounds.contains(point)
        else { return nil }

        return interactionTarget(at: point, event: event)
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = languageLabel.intrinsicContentSize
        let barHeight = labelSize.height + CodeViewConfiguration.barPadding * 2
        let textSize = textView.intrinsicContentSize
        let supposedHeight = CodeViewConfiguration.intrinsicHeight(lineCount: cachedLineCount, theme: theme)

        let lineNumberWidth = lineNumberView.intrinsicContentSize.width

        return CGSize(
            width: max(
                labelSize.width + CodeViewConfiguration.barPadding * 2,
                lineNumberWidth + textSize.width + CodeViewConfiguration.codePadding * 2
            ),
            height: max(
                barHeight + textSize.height + CodeViewConfiguration.codePadding * 2,
                supposedHeight
            )
        )
    }

    @objc func handleCopy(_: UIButton) {
        UIPasteboard.general.string = content
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc func handlePreview(_: UIButton) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        previewAction?(language, textView.attributedText)
    }

    func updateLineNumberView() {
        let font = theme.fonts.code

        let textViewContentHeight = textView.intrinsicContentSize.height

        lineNumberView.configure(
            lineCount: cachedLineCount,
            contentHeight: textViewContentHeight,
            font: font,
            textColor: theme.colors.body.withAlphaComponent(0.5)
        )

        lineNumberView.padding = UIEdgeInsets(
            top: CodeViewConfiguration.codePadding,
            left: CodeViewConfiguration.lineNumberPadding,
            bottom: CodeViewConfiguration.codePadding,
            right: CodeViewConfiguration.lineNumberPadding
        )
    }
}

extension CodeView: TextLabel.AttachmentRepresentable {
    func attributedStringRepresentation() -> NSAttributedString {
        textView.attributedText
    }
}
