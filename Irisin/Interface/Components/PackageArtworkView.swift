//
//  PackageArtworkView.swift
//  Irisin
//

import AptRepository
import ScribbleLetter
import SDWebImage
import SnapKit
import Then
import UIKit

/// A package's picture, which may never come. Until it does, and when there
/// is none, the package's name writes itself out over and over; when it
/// does, it fades in over the handwriting.
final class PackageArtworkView: UIView {
    let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.sd_imageTransition = .fade(duration: 0.35)
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

    /// Takes the handwriting along with a resize. Called inside the
    /// animation that resizes this view, after its layout pass, with the
    /// size the view had before: the handwriting draws shape layers whose
    /// paths are set for its bounds and cannot animate, and the table lays
    /// a cell out where it will be before it animates it there, so by now
    /// the name is drawn in its new place at its new size. It is put back
    /// where it was with a transform, and the transform animates away.
    func carryHandwriting(from old: CGSize) {
        layoutIfNeeded()
        let box = { (size: CGSize) in CGSize(width: size.width * 0.7, height: size.height * 0.35) }
        let before = scribble.sizeThatFits(box(old)).width
        let now = scribble.sizeThatFits(box(bounds.size)).width
        guard old != bounds.size, before > 0, now > 0 else { return }
        UIView.performWithoutAnimation {
            // a pass that did animate it there must not move it twice
            scribble.layer.removeAllAnimations()
            scribble.transform = CGAffineTransform(
                translationX: (old.width - bounds.width) / 2,
                y: (old.height - bounds.height) / 2
            ).scaledBy(x: before / now, y: before / now)
        }
        scribble.transform = .identity
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

    /// An uncached picture waiting for its moment (`load(_:uncachedNotBefore:)`).
    private var pendingLoad: Task<Void, Never>?

    /// Shows the picture at `url`. The one on show stays until the new one
    /// has arrived; no `url` takes it away and the handwriting shows again.
    /// A picture SDWebImage has cached loads at once; one that must be
    /// fetched is not asked for before `deadline`, so it cannot land in the
    /// middle of the transition that brings its page in.
    func load(_ url: URL?, uncachedNotBefore deadline: ContinuousClock.Instant? = nil) {
        pendingLoad?.cancel()
        pendingLoad = nil
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
        guard let deadline, deadline > .now, !Self.isCached(url) else {
            fetch(url)
            return
        }
        pendingLoad = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.fetch(url)
        }
    }

    /// In memory, or on disk where reading it takes no time worth waiting for.
    private static func isCached(_ url: URL) -> Bool {
        guard let key = SDWebImageManager.shared.cacheKey(for: url) else { return false }
        return SDImageCache.shared.imageFromMemoryCache(forKey: key) != nil
            || SDImageCache.shared.diskImageDataExists(withKey: key)
    }

    private func fetch(_ url: URL) {
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
