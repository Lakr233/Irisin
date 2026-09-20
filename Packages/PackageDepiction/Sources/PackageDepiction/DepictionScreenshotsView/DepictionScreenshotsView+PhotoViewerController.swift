//
//  DepictionScreenshotsView+PhotoViewerController.swift
//  JsonDepiction
//
//  A full-screen viewer for a row of images: swipe sideways between them,
//  pinch and double-tap zoom, drag to dismiss, share. It animates out of
//  the view the image was tapped in and back into the one on show.
//

import LinkPresentation
import SnapKit
import UIKit

extension DepictionScreenshotsView {
    final class PhotoViewerController: UIViewController {
        /// The image views the pictures were tapped in, in page order. The
        /// viewer shows their images and grows out of and shrinks back into them.
        private let sourceViews: [UIImageView]
        private var index: Int

        private let backdrop = UIView()
        /// Pages sideways; each page is a zooming scroll view around one image.
        private let pager = UIScrollView()
        private var pages: [UIScrollView] = []
        private var imageViews: [UIImageView] = []
        private let chrome = UIStackView()
        private let gap: CGFloat = 16

        /// - Parameters:
        ///   - sourceViews: the image views to page through; each holds its image.
        ///   - index: the page to open on.
        init(sourceViews: [UIImageView], index: Int) {
            self.sourceViews = sourceViews
            self.index = index
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .overFullScreen
            modalPresentationCapturesStatusBarAppearance = true
            transitioningDelegate = self
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var prefersStatusBarHidden: Bool {
            true
        }

        override var prefersHomeIndicatorAutoHidden: Bool {
            true
        }

        private var sourceView: UIImageView {
            sourceViews[index]
        }

        private var image: UIImage? {
            sourceView.image
        }

        private var page: UIScrollView {
            pages[index]
        }

        private var imageView: UIImageView {
            imageViews[index]
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear

            backdrop.backgroundColor = .black
            view.addSubview(backdrop)

            pager.isPagingEnabled = true
            pager.delegate = self
            pager.showsHorizontalScrollIndicator = false
            pager.contentInsetAdjustmentBehavior = .never
            view.addSubview(pager)

            for source in sourceViews {
                let page = UIScrollView()
                page.delegate = self
                page.minimumZoomScale = 1
                page.maximumZoomScale = 4
                page.showsVerticalScrollIndicator = false
                page.showsHorizontalScrollIndicator = false
                page.contentInsetAdjustmentBehavior = .never
                let imageView = UIImageView(image: source.image)
                imageView.contentMode = .scaleAspectFill
                imageView.isAccessibilityElement = true
                imageView.accessibilityTraits = .image
                imageView.accessibilityLabel = source.accessibilityLabel
                page.addSubview(imageView)
                pager.addSubview(page)
                pages.append(page)
                imageViews.append(imageView)
            }

            chrome.axis = .horizontal
            chrome.spacing = 8
            chrome.addArrangedSubview(chromeButton(
                symbol: "square.and.arrow.up",
                label: String(localized: "Share"),
                action: #selector(share)
            ))
            chrome.addArrangedSubview(chromeButton(
                symbol: "xmark",
                label: String(localized: "Close"),
                action: #selector(close)
            ))
            view.addSubview(chrome)
            chrome.snp.makeConstraints { make in
                make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
                make.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            }

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            singleTap.require(toFail: doubleTap)
            pager.addGestureRecognizer(singleTap)
            pager.addGestureRecognizer(doubleTap)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
            // one drag does one thing: a vertical one closes and the pager
            // stays put, a sideways one pages and nothing shrinks
            pager.panGestureRecognizer.require(toFail: pan)
            for page in pages {
                page.panGestureRecognizer.require(toFail: pan)
            }
        }

        /// A symbol on a round of glass, so it reads over any picture: liquid
        /// glass where the system has it, a dark material before that.
        private func chromeButton(symbol: String, label: String, action: Selector) -> UIView {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .semibold)
            config.baseForegroundColor = .white
            let button = UIButton(configuration: config)
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)

            let round: UIVisualEffectView
            if #available(iOS 26, *) {
                let glass = UIGlassEffect()
                glass.isInteractive = true
                round = UIVisualEffectView(effect: glass)
                round.cornerConfiguration = .capsule()
            } else {
                round = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
                round.layer.cornerRadius = 22
                round.clipsToBounds = true
            }
            round.contentView.addSubview(button)
            round.snp.makeConstraints { make in
                make.size.equalTo(44)
            }
            button.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            return round
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            backdrop.frame = view.bounds
            // the pager is a gap wider than the page, so pages sit apart
            let stride = CGRect(x: 0, y: 0, width: view.bounds.width + gap, height: view.bounds.height)
            // compared and set as bounds and centre, never as a frame: a drag
            // scales the pager, and a frame set under that transform inflates
            // its bounds until the neighbouring pages show
            guard pager.bounds.size != stride.size else { return }
            pager.bounds = CGRect(origin: pager.bounds.origin, size: stride.size)
            pager.center = CGPoint(x: stride.midX, y: stride.midY)
            pager.contentSize = CGSize(width: stride.width * CGFloat(pages.count), height: stride.height)
            for (i, page) in pages.enumerated() {
                page.frame = CGRect(
                    x: stride.width * CGFloat(i),
                    y: 0,
                    width: view.bounds.width,
                    height: view.bounds.height
                )
                page.zoomScale = 1
                imageViews[i].frame = CGRect(
                    origin: .zero,
                    size: fittedSize(of: sourceViews[i].image, in: page.bounds.size)
                )
                page.contentSize = imageViews[i].frame.size
                center(page)
            }
            pager.contentOffset = CGPoint(x: stride.width * CGFloat(index), y: 0)
        }

        private func fittedSize(of image: UIImage?, in size: CGSize) -> CGSize {
            guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            return CGSize(width: image.size.width * scale, height: image.size.height * scale)
        }

        private func center(_ page: UIScrollView) {
            guard let i = pages.firstIndex(of: page) else { return }
            let bounds = page.bounds.size
            let imageView = imageViews[i]
            var frame = imageView.frame
            frame.origin.x = max(0, (bounds.width - frame.width) / 2)
            frame.origin.y = max(0, (bounds.height - frame.height) / 2)
            imageView.frame = frame
        }

        // MARK: - Actions

        @objc private func close() {
            dismiss(animated: true)
        }

        @objc private func share(_ sender: UIButton) {
            guard let image else { return }
            let item = PhotoShareItem(image: image, title: sourceView.accessibilityLabel)
            let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = sender
            present(sheet, animated: true)
        }

        @objc private func toggleChrome() {
            UIView.animate(withDuration: 0.2) {
                self.chrome.alpha = self.chrome.alpha == 0 ? 1 : 0
            }
        }

        @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
            if page.zoomScale > page.minimumZoomScale {
                page.setZoomScale(page.minimumZoomScale, animated: true)
                return
            }
            let scale: CGFloat = 2.5
            let point = tap.location(in: imageView)
            let size = CGSize(width: page.bounds.width / scale, height: page.bounds.height / scale)
            page.zoom(
                to: CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                animated: true
            )
        }

        @objc private func drag(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: view)
            let progress = min(1, abs(translation.y) / (view.bounds.height / 2))
            switch pan.state {
            case .began:
                // only the picture on show moves with the finger: the pager
                // settles on it and cannot page until the drag is over
                pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(index), y: 0), animated: false)
                pager.isScrollEnabled = false
                for (i, page) in pages.enumerated() {
                    page.isHidden = i != index
                }
                sourceView.alpha = 0
            case .changed:
                let scale = 1 - progress * 0.25
                pager.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                    .scaledBy(x: scale, y: scale)
                backdrop.alpha = 1 - progress
                chrome.alpha = 0
            case .ended, .cancelled:
                pager.isScrollEnabled = true
                if progress > 0.3 || abs(pan.velocity(in: view).y) > 900 {
                    dismiss(animated: true)
                } else {
                    for page in pages {
                        page.isHidden = false
                    }
                    sourceView.alpha = 1
                    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                        self.pager.transform = .identity
                        self.backdrop.alpha = 1
                        self.chrome.alpha = 1
                    }
                }
            default:
                break
            }
        }
    }
}

// MARK: - Paging and zooming

extension DepictionScreenshotsView.PhotoViewerController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pages.firstIndex(of: scrollView).map { imageViews[$0] }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0 else { return }
        index = min(max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())), pages.count - 1)
    }
}

extension DepictionScreenshotsView.PhotoViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer,
              page.zoomScale <= page.minimumZoomScale
        else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Transition

extension DepictionScreenshotsView.PhotoViewerController: UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    func animationController(
        forPresented _: UIViewController,
        presenting _: UIViewController,
        source _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        self
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.45
    }

    /// Where the image on show sits in its source view, in this controller's
    /// coordinates, or nil when the source view is gone.
    private var sourceFrame: CGRect? {
        guard let superview = sourceView.superview, sourceView.window != nil else { return nil }
        return superview.convert(sourceView.frame, to: view)
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let presenting = context.viewController(forKey: .to) === self
        let container = context.containerView
        if presenting {
            view.frame = context.finalFrame(for: self)
            container.addSubview(view)
            view.layoutIfNeeded()
        }

        // The pager is swapped for a plain image view for the duration of
        // the animation so a zoomed or dragged image animates from where
        // it actually is.
        let ghost = UIImageView(image: image)
        ghost.contentMode = .scaleAspectFill
        ghost.clipsToBounds = true
        let restingFrame = page.convert(imageView.frame, to: view)
        let sourceRadius = sourceView.layer.cornerRadius
        let fallback = CGRect(x: view.bounds.midX - 20, y: view.bounds.midY - 20, width: 40, height: 40)
        let anchored = sourceFrame != nil

        ghost.frame = presenting ? (sourceFrame ?? fallback) : restingFrame
        ghost.layer.cornerRadius = presenting ? sourceRadius : 0
        ghost.alpha = presenting && !anchored ? 0 : 1
        view.addSubview(ghost)
        pager.isHidden = true
        // faded, never hidden: a hidden view collapses out of a stack row
        // and the row's scroll position would drift under the next tap
        let source = sourceView
        source.alpha = 0

        if presenting {
            backdrop.alpha = 0
            chrome.alpha = 0
        }

        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0
        ) {
            ghost.frame = presenting ? restingFrame : (self.sourceFrame ?? fallback)
            ghost.layer.cornerRadius = presenting ? 0 : sourceRadius
            ghost.alpha = presenting || anchored ? 1 : 0
            self.backdrop.alpha = presenting ? 1 : 0
            self.chrome.alpha = presenting ? 1 : 0
        } completion: { _ in
            ghost.removeFromSuperview()
            self.pager.isHidden = false
            source.alpha = 1
            if !presenting {
                self.view.removeFromSuperview()
            }
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}

// MARK: - Sharing

extension DepictionScreenshotsView.PhotoViewerController {
    /// The picture as the share sheet receives it, with the header filled in:
    /// the picture itself as the preview and its caption as the title.
    private final class PhotoShareItem: NSObject, UIActivityItemSource {
        private let image: UIImage
        private let title: String?

        init(image: UIImage, title: String?) {
            self.image = image
            self.title = title
        }

        func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
            image
        }

        func activityViewController(_: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?) -> Any? {
            image
        }

        func activityViewController(
            _: UIActivityViewController,
            subjectForActivityType _: UIActivity.ActivityType?
        ) -> String {
            title ?? ""
        }

        func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
            let metadata = LPLinkMetadata()
            metadata.title = title
            metadata.imageProvider = NSItemProvider(object: image)
            metadata.iconProvider = NSItemProvider(object: image)
            return metadata
        }
    }
}
