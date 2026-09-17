//
//  ArtworkView.swift
//  Irisin
//

import AptRepository
import CoreImage
import ScribbleLetter
import SDWebImage
import SnapKit
import Then
import UIKit

/// A package's picture, which may never come. Until it does, and when there
/// is none, the package's name writes itself out over and over; when it
/// does, it comes into focus over the handwriting.
final class ArtworkView: UIView {
    let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.sd_imageTransition = .blurFade
    }

    /// Written, held for a second, unwritten, and written again.
    private let scribble = ScribbleLetterView().then {
        $0.color = .label
        $0.timing = .tween(duration: 2, curve: .easeInOut)
        $0.loops = true
        $0.loopPause = 1
        $0.progress = 0
        // decorative: the name is on the page already
        $0.isAccessibilityElement = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .sheetBackground
        addSubview(scribble)
        addSubview(imageView)
        // the view scales the name to fit and centers it: a short one
        // stays a line of handwriting, a long one keeps clear of the edges
        scribble.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.equalToSuperview().multipliedBy(0.7)
            x.height.equalToSuperview().multipliedBy(0.35)
        }
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// The name to write while there is no picture. The handwriting knows
    /// ASCII only and skips the rest, so a name with anything else in it
    /// writes the identifier instead.
    func write(nameOf package: Package) {
        let name = PackageCenter.default.name(of: package)
        scribble.text = name.allSatisfy(\.isASCII) ? name : package.identity
        showScribble(!scribble.isHidden)
    }

    /// Playing only while it shows on screen: a hidden view would keep
    /// drawing frames, and off screen the library merely pauses its display
    /// link, which then outlives a page that closes.
    private func showScribble(_ shows: Bool) {
        scribble.isHidden = !shows
        if !shows || window == nil {
            scribble.pause()
        } else if !scribble.isPlaying {
            scribble.play()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        showScribble(!scribble.isHidden)
    }

    /// Shows the picture at `url`. The one on show stays until the new one
    /// has arrived; no `url` takes it away and the handwriting shows again.
    func load(_ url: URL?) {
        // under a picture that fades in, the old one fades out over the
        // handwriting, not over nothing
        showScribble(true)
        guard let url else {
            // cleared first: cancelling a download calls its completion at
            // once, which must not find the old picture and hide the name
            imageView.image = nil
            imageView.sd_cancelCurrentImageLoad()
            return
        }
        // the handwriting stops once a picture fully covers it: the one on
        // show, which a failed load leaves as it was
        imageView.sd_setImage(
            with: url,
            placeholderImage: imageView.image,
            options: [.highPriority, .waitTransition]
        ) { [weak self] _, _, _, _ in
            guard let self else { return }
            showScribble(imageView.image == nil)
        }
    }
}

private extension SDWebImageTransition {
    /// The picture fades in out of focus, then sharpens: a blurred copy on
    /// top of it fades in with it and out after it.
    static var blurFade: SDWebImageTransition {
        let transition = SDWebImageTransition()
        transition.duration = 0.35
        transition.animationOptions = [.allowUserInteraction, .curveEaseOut]
        let blurred = UIImageView().then {
            $0.contentMode = .scaleAspectFill
            $0.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        transition.prepares = { view, image, _, _, _ in
            view.alpha = 0
            blurred.image = image.flatMap(blur)
            blurred.alpha = 1
            blurred.frame = view.bounds
            view.addSubview(blurred)
        }
        transition.animations = { view, _ in
            view.alpha = 1
        }
        transition.completion = { _ in
            UIView.animate(withDuration: 0.5, delay: 0, options: [.allowUserInteraction, .curveEaseInOut]) {
                blurred.alpha = 0
            } completion: { _ in
                // a newer picture may be fading in under it already
                if blurred.alpha == 0 {
                    blurred.removeFromSuperview()
                }
            }
        }
        return transition
    }

    private static let context = CIContext()

    /// A small, heavily blurred copy; drawn scaled up, it looks the part.
    /// Shrunk before Core Image sees it, so the full picture is never
    /// uploaded on the main actor.
    /// ponytail: EXIF orientation is ignored, a rotated photo blurs sideways
    /// for the length of the fade.
    private static func blur(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0,
              let thumbnail = image.preparingThumbnail(
                  of: CGSize(width: 48, height: 48 * image.size.height / image.size.width)
              ),
              let source = CIImage(image: thumbnail)
        else { return nil }
        let output = source.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: source.extent)
        return context.createCGImage(output, from: source.extent).map(UIImage.init(cgImage:))
    }
}
