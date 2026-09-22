//
//  WelcomeController.swift
//  Irisin
//
//  The first page of onboarding: the app icon, a two-line title, what
//  Irisin does, and one button. Onboarding is a navigation stack in a form
//  sheet; a page after this one is pushed by its button, and the last
//  page's button finishes.
//

@preconcurrency import AlertController
import SnapKit
import Then
import UIKit

class WelcomeController: UIViewController {
    struct Feature {
        let symbol: String
        let title: String.LocalizationValue
        let detail: String.LocalizationValue
    }

    /// Raise it when onboarding changes enough to be shown again.
    private static let version = 1
    private static let seenVersionStore = Stored(key: "onboarding.seenVersion", defaultValue: 0)

    static var shouldPresent: Bool {
        seenVersionStore.wrappedValue < version
    }

    /// Onboarding, ready to present: this page in its own navigation stack.
    static func makeNavigator() -> UINavigationController {
        let controller = WelcomeController()
        controller.navigationItem.largeTitleDisplayMode = .never
        return UINavigationController(rootViewController: controller).then {
            // the first page has no title; the pages after it title it large
            $0.navigationBar.prefersLargeTitles = true
            $0.view.backgroundColor = WelcomeStyle.background
            $0.view.tintColor = .buttonNormal
            $0.navigationBar.tintColor = .buttonNormal
            $0.modalTransitionStyle = .coverVertical
            $0.modalPresentationStyle = .formSheet
            $0.isModalInPresentation = true
            $0.preferredContentSize = controller.preferredContentSize
        }
    }

    /// Ordered by how much a user cares, most first.
    private static let features: [Feature] = [
        .init(
            symbol: "magnifyingglass",
            title: "Find Tweaks",
            detail: "Search tweaks by name or author."
        ),
        .init(
            symbol: "square.stack.3d.up",
            title: "Batch Install",
            detail: "Queue several tweaks and install them at once."
        ),
        .init(
            symbol: "list.bullet.rectangle",
            title: "Preview Changes",
            detail: "See what will be added or removed before you install."
        ),
        .init(
            symbol: "hand.raised",
            title: "Block Updates",
            detail: "Keep a tweak at its current version."
        ),
        .init(
            symbol: "clock.arrow.circlepath",
            title: "Choose Version",
            detail: "Install an older version if a repository still offers it."
        ),
        .init(
            symbol: "questionmark.bubble",
            title: "Troubleshoot",
            detail: "When an install fails, see what happened and what to try next."
        ),
        .init(
            symbol: "arrow.down.doc",
            title: "Save Tweaks",
            detail: "Download a tweak's package file to keep or share."
        ),
        .init(
            symbol: "square.and.arrow.up",
            title: "Export List",
            detail: "Save or share a list of your installed tweaks."
        ),
    ]

    private let contentInsets = UIEdgeInsets(top: 28, left: 24, bottom: 28, right: 24)
    private let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
    private let contentView = UIView()
    private let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 18
        $0.alignment = .fill
        $0.distribution = .fillProportionally
    }

    private var featureRows: [UIView] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        modalTransitionStyle = .coverVertical
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 520, height: 620)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WelcomeStyle.background
        view.tintColor = .buttonNormal
        setupLayout()
        setupContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = .buttonNormal
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for (index, row) in featureRows.enumerated() {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.1 * Double(index),
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0.4,
                options: [.curveEaseInOut]
            ) {
                row.alpha = 1
            }
        }
    }

    private func setupLayout() {
        let actionBar = WelcomeActionBar(title: String(localized: "Next")) { [weak self] in
            self?.showNextPage()
        }

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)
        view.addSubview(actionBar)

        // the navigation bar stays for the pages after this one, empty here:
        // the page starts at the top of the sheet and scrolls under it
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(actionBar.snp.top)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        stackView.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(contentInsets)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func setupContent() {
        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
            $0.layer.shadowColor = WelcomeStyle.iconShadow.cgColor
            $0.layer.shadowRadius = 4
            $0.layer.shadowOffset = .zero
            $0.layer.shadowOpacity = 0.1
            $0.clipsToBounds = true
        }
        let iconContainer = UIView()
        iconContainer.addSubview(icon)
        icon.snp.makeConstraints { x in
            x.width.height.equalTo(64)
            x.top.bottom.equalToSuperview().inset(64)
            x.centerX.equalToSuperview()
            x.leading.greaterThanOrEqualToSuperview().inset(64)
        }
        stackView.addArrangedSubview(iconContainer)
        stackView.setCustomSpacing(0, after: iconContainer)

        // the translation places the line break and the name; the name is
        // tinted wherever it lands
        let title = String(localized: "Welcome to\nIrisin")
        let titleText = NSMutableAttributedString(string: title, attributes: [
            .font: WelcomeStyle.titleFont,
            .foregroundColor: WelcomeStyle.titleColor,
        ])
        titleText.addAttribute(.foregroundColor, value: UIColor.buttonNormal, range: (title as NSString).range(of: "Irisin"))
        stackView.addArrangedSubview(UILabel().then {
            $0.numberOfLines = 0
            $0.textAlignment = .left
            $0.attributedText = titleText
            // the page has no navigation title: this is its heading
            $0.accessibilityTraits = .header
        })

        stackView.addArrangedSubview(UILabel().then {
            $0.text = String(localized: "Find, install and manage tweaks.")
            $0.font = WelcomeStyle.subtitleFont
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        })

        let rule = UIView().then { $0.backgroundColor = .separator }
        rule.snp.makeConstraints { x in
            x.height.equalTo(0.75)
        }
        stackView.addArrangedSubview(rule)

        for (index, feature) in Self.features.enumerated() {
            let row = WelcomeFeatureRow(feature: feature)
            row.alpha = 0
            featureRows.append(row)
            stackView.addArrangedSubview(row)
            if index < Self.features.count - 1 {
                stackView.setCustomSpacing(10, after: row)
            }
        }

        // room under the last row before the button bar
        let spacer = UIView()
        spacer.snp.makeConstraints { x in
            x.height.greaterThanOrEqualTo(12)
        }
        stackView.addArrangedSubview(spacer)
    }

    private func showNextPage() {
        let page = WelcomeRepositoriesController { [weak self] in self?.finish() }
        navigationController?.pushViewController(page, animated: true)
    }

    /// Ends onboarding. The last page's button calls this.
    private func finish() {
        Self.seenVersionStore.wrappedValue = Self.version
        navigationController?.dismiss(animated: true)
    }
}
