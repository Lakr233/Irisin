//
//  ContextViewAttachment.swift
//  MarkdownView
//

import Foundation
import Litext
import MarkdownParser
import UIKit

/// The attachment a code block or a table stands on in the document.
///
/// Two of these compare equal when they describe the same thing drawn at the
/// same size, so a rebuilt document whose code blocks and tables did not
/// change compares equal to the one it replaces, and the label keeps its
/// layout instead of typesetting the whole document again. The view itself
/// is carried separately under ``NSAttributedString/Key/contextView`` and
/// compared by identity there.
///
/// Anything that can change what the block looks like or how much room it
/// takes belongs in ``Appearance``. Leaving something out is the dangerous
/// direction: two attachments that compare equal let the label keep a layout
/// built for the other one.
final class ContextViewAttachment: TextLabel.Attachment, Hashable {
    /// Everything about the block that reaches the screen.
    struct Appearance: Equatable, @unchecked Sendable {
        enum Kind: Equatable {
            /// `content` is the text the code view shows, trimmed as shown.
            case code(language: String, content: String)
            /// The cells as the table shows them, after `<br>` became a newline.
            case table(cells: [[NSAttributedString]], columnAlignments: [RawTableColumnAlignment])
        }

        let kind: Kind
        let theme: MarkdownTheme
        /// The size the view asked for, and so the room the text reserves.
        let size: CGSize
    }

    /// What copying the block yields. Immutable: a copy is taken on the way in.
    private struct Payload: @unchecked Sendable {
        let representation: NSAttributedString
        let appearance: Appearance
    }

    private nonisolated let payload: Payload

    var appearance: Appearance {
        payload.appearance
    }

    init(representation: NSAttributedString, appearance: Appearance) {
        payload = .init(
            representation: representation.copy() as! NSAttributedString,
            appearance: appearance
        )
        super.init()
    }

    override func attributedStringRepresentation() -> NSAttributedString {
        payload.representation
    }

    nonisolated static func == (lhs: ContextViewAttachment, rhs: ContextViewAttachment) -> Bool {
        if lhs === rhs {
            return true
        }
        return lhs.payload.appearance == rhs.payload.appearance
            && lhs.payload.representation.isEqual(to: rhs.payload.representation)
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(payload.representation.string)
        hasher.combine(payload.appearance.size.width)
        hasher.combine(payload.appearance.size.height)
    }
}

extension ContextViewAttachment.Appearance {
    @MainActor
    static func of(_ codeView: CodeView) -> Self {
        .init(
            kind: .code(language: codeView.language, content: codeView.content),
            theme: codeView.theme,
            size: codeView.intrinsicContentSize
        )
    }

    @MainActor
    static func of(_ tableView: TableView) -> Self {
        .init(
            kind: .table(cells: tableView.contents, columnAlignments: tableView.columnAlignments),
            theme: tableView.theme,
            size: CGSize(width: tableView.naturalContentWidth, height: tableView.intrinsicContentHeight)
        )
    }
}
