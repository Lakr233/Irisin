//
//  DepictionVideoView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import AVKit
import SnapKit
import UIKit

final class DepictionVideoView: DepictionView {
    private let playerViewController = AVPlayerViewController()
    private let playerLooper: AVPlayerLooper?

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let urlStr = dictionary["URL"] as? String,
              let videoURL = URL(string: urlStr),
              let width = dictionary["width"] as? CGFloat, width > 0,
              let height = dictionary["height"] as? CGFloat, height > 0
        else {
            return nil
        }
        let alignment = NSTextAlignment.depiction(dictionary["alignment"] as? Int)
        let cornerRadius = (dictionary["cornerRadius"] as? CGFloat) ?? 0

        let playerItem = AVPlayerItem(url: videoURL)
        let player = AVQueuePlayer(playerItem: playerItem)
        player.isMuted = true
        if (dictionary["loop"] as? Bool) ?? false {
            playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
        } else {
            playerLooper = nil
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        playerViewController.player = player
        playerViewController.showsPlaybackControls = (dictionary["showPlaybackControls"] as? Bool) ?? true
        let videoView: UIView = playerViewController.view
        if cornerRadius > 0 {
            videoView.layer.cornerRadius = cornerRadius
            videoView.clipsToBounds = true
        }
        addSubview(videoView)
        videoView.snp.makeConstraints { x in
            x.top.bottom.equalToSuperview()
            x.width.equalTo(width).priority(.high)
            x.width.lessThanOrEqualToSuperview()
            x.height.equalTo(videoView.snp.width).multipliedBy(height / width)
            switch alignment {
            case .center: x.centerX.equalToSuperview()
            case .right: x.right.equalToSuperview()
            default: x.left.equalToSuperview()
            }
        }

        if (dictionary["autoplay"] as? Bool) ?? false {
            player.play()
        }
    }
}
