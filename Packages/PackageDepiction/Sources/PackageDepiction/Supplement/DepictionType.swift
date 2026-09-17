//
//  DepictionType.swift
//  JsonDepiction
//

import UIKit

/// Every word a depiction sets is body-sized. Weight marks what matters
/// (regular against semibold) and opacity marks what matters less (the label
/// colour against the same colour faded); size never changes.
extension UIFont {
    static let depictionBody = UIFont.preferredFont(forTextStyle: .body)
    static let depictionBodyEmphasized = UIFont.systemFont(
        ofSize: depictionBody.pointSize,
        weight: .semibold
    )

    /// The body font carrying the bold and italic of imported html.
    static func depictionBody(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let base: UIFont = traits.contains(.traitBold) ? .depictionBodyEmphasized : .depictionBody
        guard traits.contains(.traitItalic),
              let descriptor = base.fontDescriptor.withSymbolicTraits(
                  base.fontDescriptor.symbolicTraits.union(.traitItalic)
              )
        else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}

extension UIColor {
    static let depictionSecondaryLabel = UIColor.label.withAlphaComponent(0.55)

    /// The colour a tinted control shows while pressed: the same hue, a
    /// quarter darker.
    var pressed: UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness * 0.75, alpha: 1)
    }
}

extension NSTextAlignment {
    /// The json's `alignment`: 1 centred, 2 right, anything else left.
    static func depiction(_ raw: Int?) -> NSTextAlignment {
        switch raw {
        case 1: .center
        case 2: .right
        default: .left
        }
    }
}
