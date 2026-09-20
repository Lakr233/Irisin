//
//  DepictionImageView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SDWebImage
import SnapKit
import Then
import UIKit

final class DepictionImageView: DepictionView {
    private let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.clipsToBounds = true
        // The json's size wins over the bitmap's: an image view resists
        // compression at 750, the same as the asked-for width below, and a
        // tie lets a 1024px avatar spill to the row's width.
        $0.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        $0.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        $0.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        $0.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
    }

    /// The size the json asks for. A zero side is filled in from the image
    /// once it arrives; until then that side is zero and the view is flat.
    private var size: CGSize
    private let alignment: NSTextAlignment
    private let xPadding: CGFloat

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let url = dictionary["URL"] as? String else {
            return nil
        }
        let width = (dictionary["width"] as? CGFloat) ?? 0
        let height = (dictionary["height"] as? CGFloat) ?? 0
        guard width != 0 || height != 0 else {
            return nil
        }
        guard let cornerRadius = dictionary["cornerRadius"] as? CGFloat else {
            return nil
        }
        size = CGSize(width: width, height: height)
        alignment = .depiction(dictionary["alignment"] as? Int)
        xPadding = (dictionary["xPadding"] as? CGFloat) ?? 0

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        imageView.layer.cornerRadius = cornerRadius
        addSubview(imageView)
        applySize()

        SDWebImageManager.shared.loadImage(
            with: URL(string: url),
            options: .highPriority,
            progress: nil
        ) { [weak self] image, _, _, _, _, _ in
            guard let self, let image, image.size.width > 0, image.size.height > 0 else { return }
            imageView.image = image
            if size.width == 0 {
                size.width = size.height * image.size.width / image.size.height
            }
            if size.height == 0 {
                size.height = size.width * image.size.height / image.size.width
            }
            applySize()
        }
    }

    /// The asked-for width, shrunk with its ratio kept when the row is
    /// narrower than that.
    private func applySize() {
        imageView.snp.remakeConstraints { x in
            x.top.bottom.equalToSuperview()
            x.width.equalTo(size.width).priority(.high)
            x.width.lessThanOrEqualToSuperview().offset(-xPadding)
            if size.width > 0 {
                x.height.equalTo(imageView.snp.width).multipliedBy(size.height / size.width)
            } else {
                x.height.equalTo(size.height)
            }
            switch alignment {
            case .center: x.centerX.equalToSuperview()
            case .right: x.right.equalToSuperview()
            default: x.left.equalToSuperview()
            }
        }
    }
}
