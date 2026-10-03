//
//  Created by ktiays on 2025/1/22.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext

final class CodeView: UIView {
    // MARK: - CONTENT

    private var needsTextRebuild = false

    var theme: MarkdownTheme = .default {
        didSet {
            languageLabel.font = theme.fonts.code
            applyBackgroundColors()
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            updateLineNumberView()
            if oldValue.fonts.code != theme.fonts.code
                || oldValue.colors.code != theme.colors.code
            {
                needsTextRebuild = true
            }
        }
    }

    var language: String = "" {
        didSet {
            languageLabel.text = language.isEmpty ? "</>" : language
            // The label is sized in layout.
            if oldValue != language {
                resetCopyFeedback()
                reloadActions()
                markNeedsLayout()
            }
        }
    }

    var content: String = "" {
        didSet {
            // A reused view takes another block, and a streaming block's
            // copy is already stale; either way it no longer shows "copied".
            if oldValue != content {
                resetCopyFeedback()
            }
            guard oldValue != content || needsTextRebuild else { return }
            needsTextRebuild = false
            cachedLineCount = max(content.components(separatedBy: .newlines).count, 1)
            textView.attributedText = CodeViewConfiguration.attributedCode(content, theme: theme)
            lineNumberView.updateForContent(content)
            updateLineNumberView()
            // A line can grow without the frame changing, and the text
            // view and scroll extent are sized in layout.
            markNeedsLayout()
        }
    }

    private var cachedLineCount: Int = 1

    // MARK: CONTENT -

    var previewAction: ((String?, NSAttributedString) -> Void)? {
        didSet {
            guard (oldValue == nil) != (previewAction == nil) else { return }
            markNeedsLayout()
        }
    }

    /// Supplies the host's own buttons, asked again when the language changes.
    weak var actionProvider: CodeBlockActionProvider? {
        didSet {
            guard oldValue !== actionProvider else { return }
            reloadActions()
        }
    }

    var actions: [CodeBlockAction] = []

    lazy var barView: UIView = .init()
    lazy var scrollView: HorizontalClippingScrollView = .init()
    lazy var copyButton: UIButton = .init()
    lazy var expandButton: UIButton = .init()
    lazy var previewButton: UIButton = .init()
    var actionButtons: [UIButton] = []

    lazy var languageLabel: BarTextLabel = .init()
    lazy var textView: TextLabelView = .init()
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
        for button in barButtons where !button.isHidden {
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
        showCopyFeedback()
    }

    @objc func handlePreview(_: UIButton) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        previewAction?(language, textView.attributedText)
    }

    @objc func handleExpand(_: UIButton) {
        CodeSheetPresenter.present(self)
    }

    func updateLineNumberView() {
        let font = theme.fonts.code

        let textViewContentHeight = textView.intrinsicContentSize.height

        lineNumberView.configure(
            lineCount: cachedLineCount,
            contentHeight: textViewContentHeight,
            lineSpacing: CodeViewConfiguration.codeLineSpacing,
            font: font,
            textColor: theme.colors.body.withAlphaComponent(0.5)
        )

        lineNumberView.padding = .init(
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
