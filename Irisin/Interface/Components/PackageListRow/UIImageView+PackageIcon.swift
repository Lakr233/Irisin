//
//  UIImageView+PackageIcon.swift
//  Irisin
//

import AptRepository
import SDWebImage
import UIKit

/// The one way a package's icon reaches a view. The view remembers the
/// address it was last asked for (`sd_imageURL`), and a new request
/// replaces the one before it, so a row needs no token of its own to keep a
/// slow answer for its last package off its next one.
extension UIImageView {
    /// Shows the icon of `package`: the default icon until it arrives,
    /// except where the view already shows that same address, whose picture
    /// stays while it loads again. A row redrawn in place never blinks.
    func showIcon(of package: Package) {
        let url = PackageCenter.default.avatarUrl(with: package)
        let shown = url != nil && sd_imageURL == url ? image : nil
        sd_setImage(
            with: url,
            placeholderImage: shown ?? .packageDefaultIcon,
            options: .highPriority
        )
    }

    /// Shows a picture that is no package's icon, or none, and forgets the
    /// address: a load still out does not land on it, and the next package
    /// does not take it for its own.
    func showIcon(_ image: UIImage?) {
        sd_setImage(with: nil, placeholderImage: image)
    }
}
