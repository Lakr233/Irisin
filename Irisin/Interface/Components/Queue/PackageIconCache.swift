//
//  PackageIconCache.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import SDWebImage
import UIKit

/// The package icons one list shows: the default icon until a package's own
/// arrives, then `arrived` redraws the list.
final class PackageIconCache {
    private var icons: [URL: UIImage] = [:]
    private let arrived: () -> Void

    init(arrived: @escaping () -> Void) {
        self.arrived = arrived
    }

    func icon(of package: Package) -> UIImage? {
        let placeholder = UIImage.packageDefaultIcon
        guard let url = PackageCenter.default.avatarUrl(with: package) else { return placeholder }
        if let icon = icons[url] {
            return icon
        }
        SDWebImageManager.shared.loadImage(with: url, options: .highPriority, progress: nil) { [weak self] image, _, _, _, _, _ in
            // a cached icon answers inside the cell provider; redraw after it
            Task { [weak self] in
                guard let self, let image, icons[url] == nil else { return }
                icons[url] = image
                arrived()
            }
        }
        return placeholder
    }
}
