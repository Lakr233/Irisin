//
//  UIColor+Surfaces.swift
//  Irisin
//
//  The grounds a screen is built on, lowest first: the iPad sidebar, the
//  page, a card on either, a sheet.
//

import UIKit

extension UIColor {
    /// The lowest ground in both modes: the iPad sidebar, with the detail
    /// column beside it (`.pageBackground`) a step brighter, and the
    /// package page's ground behind its photo, under a card of
    /// `.plainBackground`.
    static let panelBackground = UIColor(light: UIColor(hex: 0xF2F2F7), dark: .black)

    /// Page background behind cards and lists, a step above
    /// `.panelBackground` in both modes: in the dark, black on a page of its
    /// own and `elevatedGround` in the iPad detail column
    /// (`ColumnHostController` elevates it) and in a sheet.
    static let pageBackground = ground(light: UIColor(hex: 0xFAFAFA))

    /// A plain page, whose rows and text sit on the ground itself: white in
    /// light mode, in the dark as `.pageBackground`.
    static let plainBackground = ground(light: .systemBackground)

    /// An inset-grouped list's ground, a half-height form sheet's among
    /// them: `.systemGroupedBackground` in light mode, so the rows read as
    /// cards, in the dark as `.pageBackground`. A colour of our own, since a
    /// sheet clears the system one and turns to glass on iOS 26.
    static let groupedBackground = ground(light: .systemGroupedBackground)

    /// A card, a step above the ground it sits on: the iPad sidebar's
    /// navigation tiles and repository rows alike. White in light mode; in
    /// the dark, the inset-grouped cell of the ground's level.
    static let cardBackground = UIColor.secondarySystemGroupedBackground

    /// A photo's ground while it loads, a step off `.plainBackground` in
    /// both modes and at either level.
    static let sheetBackground = UIColor.secondarySystemBackground

    /// The shadow under a bar that floats over a page (`QueueBarView` before
    /// iOS 26, where glass casts its own): black in both modes, faint enough
    /// to lift a material capsule off a white list and lost on a dark one.
    static let floatingShadow = UIColor.black.withAlphaComponent(0.16)

    /// A page's ground one level up in the dark, well below the system's
    /// `#1C1C1E`: just off the black sidebar, and a wide step below the
    /// elevated cards (`#2C2C2E`) on it.
    private static let elevatedGround = UIColor(hex: 0x111111)

    /// `light` in light mode; in the dark, black at the base level and
    /// `elevatedGround` above it.
    private static func ground(light: UIColor) -> UIColor {
        UIColor { trait in
            guard trait.userInterfaceStyle == .dark else { return light.resolvedColor(with: trait) }
            return trait.userInterfaceLevel == .elevated ? elevatedGround : .black
        }
    }
}
