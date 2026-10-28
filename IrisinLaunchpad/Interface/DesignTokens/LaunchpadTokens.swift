//
//  LaunchpadTokens.swift
//  IrisinLaunchpad
//

import UIKit

/// The launchpad's type: one screen read from across a room on a
/// television, or in a window in space. Every line is set in one size;
/// weight and the text colour's opacity tell them apart. A call site picks
/// one of these, as the app's do from `Irisin/Interface/DesignTokens`;
/// nothing else names a size or a weight.
extension UIFont {
    /// The one size: the headline's on a television, the second title's in
    /// a window, which sits further off than a page of text.
    private static var launchpadSize: CGFloat {
        #if os(tvOS)
            preferredFont(forTextStyle: .headline).pointSize
        #else
            preferredFont(forTextStyle: .title2).pointSize
        #endif
    }

    /// Lines that explain: what to do, the code's caption, what is going on.
    static var launchpadText: UIFont {
        .systemFont(ofSize: launchpadSize, weight: .regular)
    }

    /// Lines that carry the screen: the address and the code, with digits
    /// of one width.
    static var launchpadEmphasis: UIFont {
        .monospacedDigitSystemFont(ofSize: launchpadSize, weight: .semibold)
    }
}

/// The launchpad's colours, by purpose: the system's own text colours, and
/// the one ground the QR code needs.
extension UIColor {
    /// Text that carries the screen: the address and the code.
    static let launchpadPrimaryText = UIColor.label

    /// Text that explains it: the same text at the system's lower opacity.
    static let launchpadSecondaryText = UIColor.secondaryLabel

    /// The ground a QR code needs around it to be read: always white, in
    /// either appearance, as the code is drawn black.
    static let launchpadCodeGround = UIColor.white
}
