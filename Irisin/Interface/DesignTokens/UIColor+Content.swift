//
//  UIColor+Content.swift
//  Irisin
//
//  What is drawn on a ground: the accent, text, glyphs and swipe actions.
//  A colour that means a state is in UIColor+Status.swift.
//

import UIKit

extension UIColor {
    /// The one accent: screen titles, buttons, tinted glyphs and badges.
    /// Blue Pencil's `#278eff` (`#58a6ff` in the dark). A colour that
    /// means a state (green installed, yellow downloading, red failed)
    /// keeps its own hue and never borrows this one.
    static let buttonNormal = UIColor(light: UIColor(hex: 0x278EFF), dark: UIColor(hex: 0x58A6FF))

    /// Text and glyphs on an accent fill: the selected navigation tile, the
    /// package page's action button.
    static let onAccent = UIColor.white

    /// The package page's action button title while it is pressed.
    static let onAccentPressed = UIColor.gray

    /// Primary label text.
    static let textTitle = UIColor(light: .black, dark: .white)

    /// Secondary label text.
    static let textSubtitle = UIColor(red: 0.471, green: 0.518, blue: 0.620, alpha: 1)

    /// Quiet text that is not a subtitle: an unselected navigation tile's
    /// title, a package collection's count, the line under a spinner.
    static let textMuted = UIColor.gray

    /// A search results section's title.
    static let sectionCaption = UIColor.gray.withAlphaComponent(0.5)

    /// The question mark on an empty package collection.
    static let placeholderGlyph = UIColor.gray.withAlphaComponent(0.2)

    /// The name of a package sold through its repository.
    static let paidPackage = UIColor.systemPink

    /// Marker behind a search match inside text.
    static let searchHighlight = UIColor(hex: 0xFDF794)

    /// A search match on `.searchHighlight`: dark in both modes, since the
    /// marker is light in both.
    static let searchHighlightText = UIColor.black

    /// Swipe actions: destructive, refresh, share.
    static let swipeDelete = UIColor(hex: 0xFA685C)
    static let swipeRefresh = UIColor(hex: 0x7A95DF)
    static let swipeShare = UIColor(hex: 0xBA82D0)

    /// A bar button that deletes the selection.
    static let destructiveAction = UIColor.systemRed

    /// The ring of a selection mark on a row that is not selected.
    static let selectionMarkIdle = UIColor.systemGray3
}
