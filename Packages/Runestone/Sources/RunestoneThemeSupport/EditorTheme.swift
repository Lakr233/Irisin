import Runestone
import UIKit

/// A theme that also names the ground the text view sits on and whether it is
/// drawn for light or dark.
public protocol EditorTheme: Runestone.Theme {
    var backgroundColor: UIColor { get }
    var userInterfaceStyle: UIUserInterfaceStyle { get }
}

/// The capture names the themes colour. A dotted name falls back to its
/// prefix (`string.special.key` reads as `string`); anything else keeps the
/// text colour.
enum HighlightName: String {
    case comment
    case function
    case keyword
    case number
    case `operator`
    case property
    case punctuation
    case string
    case variableBuiltin = "variable.builtin"

    init?(_ rawHighlightName: String) {
        var components = rawHighlightName.split(separator: ".")
        while !components.isEmpty {
            if let highlightName = Self(rawValue: components.joined(separator: ".")) {
                self = highlightName
                return
            }
            components.removeLast()
        }
        return nil
    }
}

extension UIColor {
    /// `0xRRGGBB` in sRGB, the way the upstream colour sets spell them.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
