//
//  WelcomeStyle.swift
//  Irisin
//

import UIKit

/// FlowDown's welcome typography and system colors, kept separate from
/// Irisin's type ramp so the copied page retains its original appearance.
enum WelcomeStyle {
    /// The fixed, bold, two-line heading in FlowDown's welcome page.
    static var titleFont: UIFont { .systemFont(ofSize: 32, weight: .bold) }

    /// The system body style used for the welcome introduction.
    static var subtitleFont: UIFont { .preferredFont(forTextStyle: .body) }

    /// The system subheadline with the same bold trait as FlowDown's rows.
    static var featureTitleFont: UIFont {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// The system footnote style used under each feature title.
    static var detailFont: UIFont { .preferredFont(forTextStyle: .footnote) }

    /// The system headline assigned before the filled button configuration.
    static var buttonFont: UIFont { .preferredFont(forTextStyle: .headline) }

    /// FlowDown's fixed-size, medium-weight feature symbols.
    static var featureSymbol: UIImage.SymbolConfiguration {
        .init(pointSize: 16, weight: .medium)
    }

    /// The system sheet ground of the original welcome page.
    static var background: UIColor { .systemBackground }

    /// Primary system label text, as in the original welcome page.
    static var titleColor: UIColor { .label }

    /// Secondary system label text, as in the original welcome page.
    static var detailColor: UIColor { .secondaryLabel }

    /// The app icon's shadow in the original welcome page.
    static var iconShadow: UIColor { .black }

    /// The warning symbol on the page that asks for care.
    static var caution: UIColor { .systemOrange }
}
