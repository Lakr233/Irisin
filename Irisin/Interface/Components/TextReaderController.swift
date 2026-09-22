//
//  TextReaderController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import RunestoneEditor
import RunestoneLanguageSupport
import RunestoneThemeSupport
import SnapKit
import Then
import UIKit

/// Text to read, the way Fila opens a file: Runestone's text view with line
/// numbers, lines that run past the edge until the toggle wraps them, and
/// Share. A maintainer script brings its grammar; a package's control fields
/// are plain text. Nothing here edits.
final class TextReaderController: UIViewController {
    private let text: String
    private let language: TreeSitterLanguage?
    private let textView = TextView()

    init(title: String, text: String, language: TreeSitterLanguage? = nil) {
        self.text = text
        self.language = language
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        let wrap = UIBarButtonItem().then {
            $0.image = UIImage(systemName: "arrow.turn.down.left")
            $0.accessibilityLabel = String(localized: "Wrap Lines")
        }
        wrap.primaryAction = UIAction(image: wrap.image) { [weak self, weak wrap] _ in
            guard let self, let wrap else { return }
            textView.isLineWrappingEnabled.toggle()
            wrap.isSelected = textView.isLineWrappingEnabled
        }
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"),
                primaryAction: UIAction { [weak self] _ in self?.share() }
            ).then { $0.accessibilityLabel = String(localized: "Share") },
            wrap,
        ]

        // a reader shows the text, not the whitespace inside it
        textView.do {
            $0.showTabs = false
            $0.showSpaces = false
            $0.showNonBreakingSpaces = false
            $0.showLineBreaks = false
            $0.showSoftLineBreaks = false
            $0.showLineNumbers = true
            $0.gutterLeadingPadding = 8
            $0.gutterTrailingPadding = 8
            $0.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            $0.lineHeightMultiplier = 1.2
            $0.spellCheckingType = .no
            $0.lineSelectionDisplayType = .line
            $0.isLineWrappingEnabled = false
            $0.isEditable = false
            $0.alwaysBounceVertical = true
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        // text, theme and grammar in one state: set apart, each parses again
        let theme = ReaderTheme(for: traitCollection)
        if let language {
            textView.setState(TextViewState(text: text, theme: theme, language: language))
        } else {
            textView.setState(TextViewState(text: text, theme: theme))
        }
        textView.backgroundColor = theme.backgroundColor
        view.backgroundColor = theme.backgroundColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        // the theme alone: a new state would parse the text again
        let theme = ReaderTheme(for: traitCollection)
        textView.theme = theme
        textView.backgroundColor = theme.backgroundColor
        view.backgroundColor = theme.backgroundColor
    }

    private func share() {
        ShareSheet.present(
            [text],
            anchor: navigationItem.rightBarButtonItem.map { PopoverAnchor($0) },
            from: self
        )
    }
}

/// One of Runestone's palettes under the app's own monospaced token: the
/// themes ship a fixed point size, and the type ramp follows Dynamic Type.
/// Everything but the font is the base theme's, forwarded.
private final class ReaderTheme: EditorTheme {
    private let base: EditorTheme
    let font = UIFont.monospaced(.footnote)
    let lineNumberFont = UIFont.monospaced(.footnote)

    init(for traits: UITraitCollection) {
        base = traits.userInterfaceStyle == .dark ? OneDarkTheme() : TomorrowTheme()
    }

    var backgroundColor: UIColor {
        base.backgroundColor
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        base.userInterfaceStyle
    }

    var textColor: UIColor {
        base.textColor
    }

    var gutterBackgroundColor: UIColor {
        base.gutterBackgroundColor
    }

    var gutterHairlineColor: UIColor {
        base.gutterHairlineColor
    }

    var gutterHairlineWidth: CGFloat {
        base.gutterHairlineWidth
    }

    var lineNumberColor: UIColor {
        base.lineNumberColor
    }

    var selectedLineBackgroundColor: UIColor {
        base.selectedLineBackgroundColor
    }

    var selectedLinesLineNumberColor: UIColor {
        base.selectedLinesLineNumberColor
    }

    var selectedLinesGutterBackgroundColor: UIColor {
        base.selectedLinesGutterBackgroundColor
    }

    var invisibleCharactersColor: UIColor {
        base.invisibleCharactersColor
    }

    var pageGuideHairlineColor: UIColor {
        base.pageGuideHairlineColor
    }

    var pageGuideHairlineWidth: CGFloat {
        base.pageGuideHairlineWidth
    }

    var pageGuideBackgroundColor: UIColor {
        base.pageGuideBackgroundColor
    }

    var markedTextBackgroundColor: UIColor {
        base.markedTextBackgroundColor
    }

    var markedTextBackgroundCornerRadius: CGFloat {
        base.markedTextBackgroundCornerRadius
    }

    func textColor(for highlightName: String) -> UIColor? {
        base.textColor(for: highlightName)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        base.fontTraits(for: highlightName)
    }
}
