//
//  CodeView+Actions.swift
//  MarkdownView
//

import Foundation
import UIKit

typealias PlatformButton = UIButton

extension CodeView {
    /// How long Copy shows a checkmark after it is tapped.
    static let copyFeedbackDuration: TimeInterval = 1.5

    static let copySymbol = TableSymbol.copy
    static let copiedSymbol = TableSymbol.copied
    static let expandSymbol = TableSymbol.expand

    /// The bar's buttons from the trailing edge: Expand, Copy, Preview, then
    /// the host's actions — Copy, Expand reading left to right. Download is
    /// in the sheet Expand opens.
    var barButtons: [PlatformButton] {
        [expandButton, copyButton, previewButton] + actionButtons.reversed()
    }

    /// Swaps Copy for a checkmark, and back after `copyFeedbackDuration`;
    /// another tap restarts the wait.
    func showCopyFeedback() {
        setCopySymbol(Self.copiedSymbol)
        schedule(#selector(resetCopyFeedback), after: Self.copyFeedbackDuration)
    }

    /// Puts Copy back and drops a pending reset, so a view reused for
    /// another block does not show — or later flip — the last one's state.
    @objc func resetCopyFeedback() {
        cancelScheduled(#selector(resetCopyFeedback))
        setCopySymbol(Self.copySymbol)
    }

    /// Asks the provider for this block's buttons and rebuilds them.
    func reloadActions() {
        actions = actionProvider?.codeBlockActions(forLanguage: language.isEmpty ? nil : language) ?? []
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons = actions.indices.map { makeActionButton(for: actions[$0], tag: $0) }
        for button in actionButtons {
            barView.addSubview(button)
        }
        markNeedsLayout()
    }

    @objc func handleAction(_ sender: Any?) {
        guard let tag = (sender as? UIView)?.tag else { return }
        guard actions.indices.contains(tag) else { return }
        actions[tag].handler(CodeBlock(language: language.isEmpty ? nil : language, content: content))
    }

    private func setCopySymbol(_ name: String) {
        let image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(scale: .small)
        )
        copyButton.setImage(image, for: .normal)
    }

    private func makeActionButton(for action: CodeBlockAction, tag: Int) -> UIButton {
        let button = UIButton()
        button.setImage(
            UIImage(
                systemName: action.systemImage,
                withConfiguration: UIImage.SymbolConfiguration(scale: .small)
            ),
            for: .normal
        )
        button.tintColor = .label
        button.tag = tag
        button.accessibilityLabel = action.title
        button.addTarget(self, action: #selector(handleAction(_:)), for: .touchUpInside)
        return button
    }
}
