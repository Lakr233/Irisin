//
//  MarkdownTheme+Depiction.swift
//  JsonDepiction
//

import MarkdownView
import UIKit

extension MarkdownTheme {
    /// The one look for the prose a depiction writes: body-sized throughout,
    /// headings told apart by weight alone, the label colour, and the
    /// depiction's tint on links.
    @MainActor
    static func depiction(tintColor: UIColor) -> MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.fonts.body = .depictionBody
        theme.fonts.title = .depictionBodyEmphasized
        theme.fonts.bold = .depictionBodyEmphasized
        theme.colors.body = .label
        theme.colors.highlight = tintColor
        theme.colors.emphasis = tintColor
        theme.colors.selectionBackground = tintColor.withAlphaComponent(0.2)
        return theme
    }
}
