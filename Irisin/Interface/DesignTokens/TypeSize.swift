//
//  TypeSize.swift
//  Irisin
//
//  The type ramp. Call sites pick a token, never a literal size or a
//  weight other than regular / semibold.
//

import UIKit

/// The type ramp. Every label in the app is one of these sizes, at the
/// user's default text size; each scales with Dynamic Type along the curve
/// of the nearest system text style (`textStyle`).
enum TypeSize: CGFloat {
    /// The welcome page's title, the one text larger than a screen title.
    case display = 32
    /// Screen titles.
    case largeTitle = 28
    /// Package names, iPad section titles.
    case title = 22
    /// Section headlines, nav card titles.
    case headline = 18
    /// Primary row text.
    case body = 16
    /// Compact body (URL field).
    case callout = 15
    /// Secondary labels, compact buttons.
    case subheadline = 14
    /// Metadata under a title.
    case footnote = 13
    /// Captions, badges, section headers.
    case caption = 12
    /// Small captions, log lines.
    case caption2 = 11
    /// SF Symbol beside a headline.
    case icon = 24

    var textStyle: UIFont.TextStyle {
        switch self {
        case .display, .largeTitle: .largeTitle
        case .title, .icon: .title2
        case .headline: .title3
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }

    var metrics: UIFontMetrics {
        UIFontMetrics(forTextStyle: textStyle)
    }

    /// The size at the current content size category.
    var scaled: CGFloat {
        metrics.scaledValue(for: rawValue)
    }
}

extension UIFont {
    /// Regular unless `emphasized`, which is semibold. No other weights.
    static func type(_ size: TypeSize, emphasized: Bool = false) -> UIFont {
        size.metrics.scaledFont(for: systemFont(ofSize: size.rawValue, weight: emphasized ? .semibold : .regular))
    }

    static func rounded(_ size: TypeSize, emphasized: Bool = false) -> UIFont {
        let weight: UIFont.Weight = emphasized ? .semibold : .regular
        var font = systemFont(ofSize: size.rawValue, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: descriptor, size: size.rawValue)
        }
        return size.metrics.scaledFont(for: font)
    }

    static func monospaced(_ size: TypeSize, emphasized: Bool = false) -> UIFont {
        size.metrics.scaledFont(
            for: monospacedSystemFont(ofSize: size.rawValue, weight: emphasized ? .semibold : .regular)
        )
    }

    static func monospacedDigit(_ size: TypeSize, emphasized: Bool = false) -> UIFont {
        size.metrics.scaledFont(
            for: monospacedDigitSystemFont(ofSize: size.rawValue, weight: emphasized ? .semibold : .regular)
        )
    }

    /// The same face with tabular digits, for counters that must not jitter.
    var monospacedDigitFont: UIFont {
        let settings = [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                         UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: settings])
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Computed, not stored: a font is scaled for the content size category
    /// in force when it is made, so a view created after the user changes the
    /// text size must get a fresh one.
    static var largeTitle: UIFont {
        type(TypeSize.largeTitle, emphasized: true)
    }

    static var title: UIFont {
        type(TypeSize.title, emphasized: true)
    }

    static var headline: UIFont {
        type(TypeSize.headline, emphasized: true)
    }

    static var body: UIFont {
        type(TypeSize.body)
    }

    static var bodyEmphasized: UIFont {
        type(TypeSize.body, emphasized: true)
    }

    static var subheadline: UIFont {
        type(TypeSize.subheadline)
    }

    static var subheadlineEmphasized: UIFont {
        type(TypeSize.subheadline, emphasized: true)
    }

    static var footnote: UIFont {
        type(TypeSize.footnote)
    }

    static var caption: UIFont {
        type(TypeSize.caption)
    }

    static var captionEmphasized: UIFont {
        type(TypeSize.caption, emphasized: true)
    }

    static var caption2: UIFont {
        type(TypeSize.caption2)
    }
}

extension UIImage.SymbolConfiguration {
    convenience init(_ size: TypeSize, emphasized: Bool = false) {
        self.init(pointSize: size.scaled, weight: emphasized ? .semibold : .regular)
    }
}

/// Views that own text follow the user's text size for as long as they
/// live. Set once at launch; every label, text view and field created after
/// picks it up when it joins a window.
///
/// Except on the newest iOS, where the appearance proxy no longer carries
/// the flag to `UILabel` (measured: true on the 18.6 simulator, ignored on
/// 27.0, while the text view and the field still take it). A label already
/// on screen there keeps the size it was built with until the view is built
/// again — which is why the font tokens above are computed and not stored.
@MainActor
func adoptDynamicTypeEverywhere() {
    UILabel.appearance().adjustsFontForContentSizeCategory = true
    UITextView.appearance().adjustsFontForContentSizeCategory = true
    UITextField.appearance().adjustsFontForContentSizeCategory = true
}
