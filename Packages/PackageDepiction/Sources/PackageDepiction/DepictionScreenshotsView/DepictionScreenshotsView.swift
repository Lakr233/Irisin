//
//  DepictionScreenshotsView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import AVKit
import SDWebImage
import SnapKit
import Then
import UIKit

/// A row of screenshots the height the json asks for, scrolled sideways
/// when wider than the page and centred when narrower. One wider than the
/// page is shrunk with its ratio kept, so its edges meet the page's gutter.
final class DepictionScreenshotsView: DepictionView {
    private let scrollView = UIScrollView().then {
        $0.decelerationRate = .fast
        $0.showsVerticalScrollIndicator = false
        $0.showsHorizontalScrollIndicator = false
    }

    private let row = UIStackView().then {
        $0.axis = .horizontal
        $0.alignment = .center
        $0.spacing = 16
    }

    private let itemSize: CGSize
    private let itemCornerRadius: CGFloat

    /// The players behind the video items, kept for as long as the row.
    private var players: [AVPlayerViewController] = []

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        var dictionary = dictionary
        let deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        if let specificDict = dictionary[deviceName] as? [String: Any] {
            dictionary = specificDict
        }

        guard let rawItemSize = dictionary["itemSize"] as? String,
              let itemCornerRadius = dictionary["itemCornerRadius"] as? CGFloat,
              let screenshots = dictionary["screenshots"] as? [[String: Any]]
        else {
            return nil
        }
        let itemSize = NSCoder.cgSize(for: rawItemSize)
        guard itemSize.width > 0, itemSize.height > 0 else {
            return nil
        }
        self.itemSize = itemSize
        self.itemCornerRadius = itemCornerRadius

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        addSubview(scrollView)
        scrollView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.height.equalTo(itemSize.height + 32)
        }
        let content = UIView()
        scrollView.addSubview(content)
        content.addSubview(row)
        content.snp.makeConstraints { x in
            x.edges.equalTo(scrollView.contentLayoutGuide)
            x.height.equalTo(scrollView.frameLayoutGuide)
            // as wide as the page, or as wide as the row when that is more
            x.width.greaterThanOrEqualTo(scrollView.frameLayoutGuide)
            x.width.equalTo(row.snp.width).offset(32).priority(.high)
        }
        row.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.left.greaterThanOrEqualToSuperview().inset(16)
        }

        for screenshot in screenshots {
            guard let urlStr = screenshot["url"] as? String,
                  let url = URL(string: urlStr),
                  let accessibilityText = screenshot["accessibilityText"] as? String
            else {
                continue
            }
            if (screenshot["video"] as? Bool) ?? false {
                addVideo(url: url)
            } else {
                addImage(url: url, accessibilityText: accessibilityText)
            }
        }
    }

    private func addVideo(url: URL) {
        let player = AVPlayerViewController()
        player.player = AVPlayer(url: url).then { $0.isMuted = true }
        players.append(player)
        let videoView: UIView = player.view
        if itemCornerRadius > 0 {
            videoView.layer.cornerRadius = itemCornerRadius
            videoView.clipsToBounds = true
        }
        row.addArrangedSubview(videoView)
        fit(videoView, ratio: itemSize.width / itemSize.height)
    }

    private func addImage(url: URL, accessibilityText: String) {
        let imageView = UIImageView().then {
            $0.contentMode = .scaleAspectFill
            $0.clipsToBounds = true
            $0.layer.cornerRadius = itemCornerRadius
            $0.isUserInteractionEnabled = true
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = accessibilityText
            $0.accessibilityTraits = [.image, .button]
            $0.accessibilityIgnoresInvertColors = true
            // the bitmap's own size never competes with `fit`'s height
            $0.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
            $0.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
            $0.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
            $0.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        }
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(fullScreenImage)))
        row.addArrangedSubview(imageView)
        fit(imageView, ratio: itemSize.width / itemSize.height)

        SDWebImageManager.shared.loadImage(
            with: url,
            options: .highPriority,
            progress: nil
        ) { [weak self, weak imageView] image, _, _, _, _, _ in
            guard let self, let imageView, let image, image.size.height > 0 else { return }
            imageView.image = image
            fit(imageView, ratio: image.size.width / image.size.height)
        }
    }

    /// The item's height is the row's and its width follows the picture;
    /// a picture wider than the page gives up height instead.
    private func fit(_ item: UIView, ratio: CGFloat) {
        item.snp.remakeConstraints { x in
            x.height.equalTo(itemSize.height).priority(.high)
            x.width.equalTo(item.snp.height).multipliedBy(ratio)
            x.width.lessThanOrEqualTo(self.snp.width).offset(-32)
        }
    }

    @objc private func fullScreenImage(_ tap: UITapGestureRecognizer) {
        // every picture that has arrived, in row order; the viewer pages
        // through them from the one tapped
        let loaded = row.arrangedSubviews.compactMap { $0 as? UIImageView }.filter { $0.image != nil }
        guard let tapped = tap.view as? UIImageView, let index = loaded.firstIndex(of: tapped) else {
            return
        }
        let controller = PhotoViewerController(sourceViews: loaded, index: index)
        var presenter = window?.rootViewController
        // present from the top of the stack: presenting on a controller that
        // already presents one throws
        while let next = presenter?.presentedViewController {
            presenter = next
        }
        presenter?.present(controller, animated: true, completion: nil)
    }
}
