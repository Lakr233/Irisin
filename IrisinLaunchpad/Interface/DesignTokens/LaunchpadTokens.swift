//
//  LaunchpadTokens.swift
//  IrisinLaunchpad
//

import UIKit

/// The launchpad's type ramp: one screen read from across a room on a
/// television, or in a window in space. A call site picks one of these, as
/// the app's do from `Irisin/Interface/DesignTokens`; nothing else names a
/// size or a weight.
extension UIFont {
    /// The app's name, at the top of the screen.
    static var launchpadTitle: UIFont {
        semibold(.title1)
    }

    /// What a block of the screen is about, and the owner's question.
    static var launchpadHeadline: UIFont {
        semibold(.title3)
    }

    /// Sentences: what to do, what is running.
    static var launchpadBody: UIFont {
        preferredFont(forTextStyle: .body)
    }

    /// The device's name and system, and the status line.
    static var launchpadCaption: UIFont {
        preferredFont(forTextStyle: .callout)
    }

    /// The page's address, typed by hand when there is no camera to hand.
    static var launchpadAddress: UIFont {
        .monospacedSystemFont(ofSize: preferredFont(forTextStyle: .title3).pointSize, weight: .regular)
    }

    /// The six digits, read from the sofa.
    static var launchpadCode: UIFont {
        .monospacedDigitSystemFont(ofSize: preferredFont(forTextStyle: .title1).pointSize * 1.8, weight: .semibold)
    }

    private static func semibold(_ style: TextStyle) -> UIFont {
        let base = preferredFont(forTextStyle: style)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}

/// The launchpad's colours, by purpose.
extension UIColor {
    /// Irisin's blue, the icon's own (#0088FF).
    static let launchpadAccent = UIColor(red: 0, green: 0x88 / 255.0, blue: 1, alpha: 1)

    /// Text that carries the screen.
    static let launchpadPrimaryText = UIColor.label

    /// Text that explains it.
    static let launchpadSecondaryText = UIColor.secondaryLabel

    /// A yes that takes something away, or is likely to fail.
    static let launchpadDestructive = UIColor.systemRed

    /// The ground a QR code needs around it to be read: always white, in
    /// either appearance, as the code is drawn black.
    static let launchpadCodeGround = UIColor.white
}
