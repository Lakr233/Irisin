@testable import irisin
import Testing
import UIKit

/// The iPad answers a popover with nowhere to point with an exception, so
/// whatever the anchor has become by the time the sheet is shown, the
/// popover must leave with a source view or a bar button that is on screen.
/// Serialized: every test puts a window of its own on the one scene.
@MainActor
@Suite(.serialized)
struct ShareSheetAnchorTests {
    /// A page on screen: in a navigation controller, in a window.
    @MainActor
    private final class Stage {
        let window: UIWindow
        let navigator: UINavigationController
        let page = UIViewController()

        init(on scene: UIWindowScene) {
            window = UIWindow(windowScene: scene)
            navigator = UINavigationController(rootViewController: page)
            window.rootViewController = navigator
            window.isHidden = false
            page.loadViewIfNeeded()
            window.layoutIfNeeded()
        }

        func strike() {
            navigator.dismiss(animated: false)
            window.rootViewController = nil
            window.isHidden = true
        }
    }

    private func withStage(_ body: (Stage) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let stage = try Stage(on: #require(scenes.first))
        defer { stage.strike() }
        try await body(stage)
    }

    /// A popover of the kind the share sheet has on the iPad, on any device.
    private func pointedPopover(
        for anchor: PopoverAnchor?,
        over presenter: UIViewController
    ) throws -> UIPopoverPresentationController {
        let content = UIViewController()
        content.modalPresentationStyle = .popover
        let popover = try #require(content.popoverPresentationController)
        ShareSheet.point(popover, at: ShareSheet.popoverTarget(for: anchor, over: presenter))
        return popover
    }

    /// Somewhere to point at all: what UIKit asks for before it throws.
    private func expectPointed(_ popover: UIPopoverPresentationController) {
        #expect(popover.sourceView != nil || popover.barButtonItem != nil)
    }

    /// Somewhere to point that is on the stage: a view in its window, or a
    /// bar button of its page while the bar shows.
    private func expectPointed(_ popover: UIPopoverPresentationController, on stage: Stage) {
        expectPointed(popover)
        if let view = popover.sourceView {
            #expect(view.window === stage.window)
        }
        if let item = popover.barButtonItem {
            let navigation = stage.page.navigationItem
            let items = (navigation.rightBarButtonItems ?? []) + (navigation.leftBarButtonItems ?? [])
            #expect(items.contains { $0 === item })
            #expect(!item.isHidden)
            #expect(stage.navigator.topViewController === stage.page)
            #expect(stage.navigator.navigationBar.window === stage.window)
            #expect(!stage.navigator.isNavigationBarHidden)
        }
    }

    private func expectCentred(_ popover: UIPopoverPresentationController, in view: UIView) {
        #expect(popover.sourceView === view)
        #expect(popover.barButtonItem == nil)
        #expect(popover.permittedArrowDirections == [])
        #expect(popover.sourceRect.size == .zero)
        #expect(popover.sourceRect.origin == CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    private func expectCentred(_ popover: UIPopoverPresentationController, on stage: Stage) {
        expectPointed(popover, on: stage)
        expectCentred(popover, in: stage.page.view)
    }

    private func button(on stage: Stage) -> UIView {
        let button = UIView(frame: CGRect(x: 10, y: 20, width: 44, height: 44))
        stage.page.view.addSubview(button)
        return button
    }

    // MARK: A view

    @Test func aViewOnScreenIsWhatThePopoverPointsAt() async throws {
        try await withStage { stage in
            let touched = button(on: stage)

            let popover = try pointedPopover(for: PopoverAnchor(touched), over: stage.page)
            #expect(popover.sourceView === touched)
            #expect(popover.sourceRect == touched.bounds)
            expectPointed(popover, on: stage)
        }
    }

    /// A cell that scrolled away while the share waited on a download.
    @Test func aViewThatLeftItsWindowGivesWayToTheMiddleOfThePage() async throws {
        try await withStage { stage in
            let cell = button(on: stage)
            let anchor = PopoverAnchor(cell)
            cell.removeFromSuperview()

            try expectCentred(pointedPopover(for: anchor, over: stage.page), on: stage)
        }
    }

    @Test func aViewThatIsGoneGivesWayToTheMiddleOfThePage() async throws {
        try await withStage { stage in
            var cell: UIView? = UIView()
            let anchor = try PopoverAnchor(#require(cell))
            cell = nil
            #expect(anchor.view == nil)

            try expectCentred(pointedPopover(for: anchor, over: stage.page), on: stage)
        }
    }

    @Test func aViewThatLeftGivesWayToThePagesBarButton() async throws {
        try await withStage { stage in
            let pageItem = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.rightBarButtonItem = pageItem
            stage.window.layoutIfNeeded()

            let popover = try pointedPopover(for: PopoverAnchor(UIView()), over: stage.page)
            #expect(popover.barButtonItem === pageItem)
            expectPointed(popover, on: stage)
        }
    }

    /// In the window and nothing to point at all the same.
    @Test func aViewNobodySeesGivesWayToTheMiddleOfThePage() async throws {
        try await withStage { stage in
            let hidden = button(on: stage)
            hidden.isHidden = true
            let clear = button(on: stage)
            clear.alpha = 0
            let empty = button(on: stage)
            empty.frame.size = .zero
            let shelf = button(on: stage)
            shelf.isHidden = true
            let inside = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            shelf.addSubview(inside)

            for view in [hidden, clear, empty, inside] {
                #expect(view.window === stage.window)
                try expectCentred(pointedPopover(for: PopoverAnchor(view), over: stage.page), on: stage)
            }
        }
    }

    /// The log page's menu button: the custom view of a bar button stays in
    /// the window when the bar is hidden.
    @Test func theCustomViewOfAHiddenBarIsNotPointedAt() async throws {
        try await withStage { stage in
            let menuButton = UIButton(type: .system)
            menuButton.setTitle("Menu", for: .normal)
            stage.page.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: menuButton)
            stage.window.layoutIfNeeded()

            let shown = try pointedPopover(for: PopoverAnchor(menuButton), over: stage.page)
            expectPointed(shown, on: stage)

            stage.navigator.setNavigationBarHidden(true, animated: false)
            try expectCentred(pointedPopover(for: PopoverAnchor(menuButton), over: stage.page), on: stage)
        }
    }

    /// The app has more than one scene's worth of windows.
    @Test func aViewInAnotherWindowIsNotPointedAt() async throws {
        try await withStage { stage in
            try await withStage { other in
                let elsewhere = button(on: other)
                #expect(elsewhere.window === other.window)

                try expectCentred(pointedPopover(for: PopoverAnchor(elsewhere), over: stage.page), on: stage)
            }
        }
    }

    // MARK: A bar button

    @Test func aBarButtonIsWhatThePopoverPointsAt() async throws {
        try await withStage { stage in
            let item = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.rightBarButtonItem = item

            let popover = try pointedPopover(for: PopoverAnchor(item), over: stage.page)
            #expect(popover.barButtonItem === item)
            expectPointed(popover, on: stage)
        }
    }

    /// The bar button of a page that was popped while the download ran: not
    /// hidden, and nowhere.
    @Test func aBarButtonOfAnotherPageIsNotPointedAt() async throws {
        try await withStage { stage in
            let stranger = UIBarButtonItem(systemItem: .action)
            #expect(!stranger.isHidden)
            try expectCentred(pointedPopover(for: PopoverAnchor(stranger), over: stage.page), on: stage)

            let pageItem = UIBarButtonItem(systemItem: .done)
            stage.page.navigationItem.rightBarButtonItem = pageItem
            let beside = try pointedPopover(for: PopoverAnchor(stranger), over: stage.page)
            #expect(beside.barButtonItem === pageItem)
            expectPointed(beside, on: stage)
        }
    }

    @Test func aBarButtonOfAHiddenBarIsNotPointedAt() async throws {
        try await withStage { stage in
            let item = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.rightBarButtonItem = item
            stage.navigator.setNavigationBarHidden(true, animated: false)

            try expectCentred(pointedPopover(for: PopoverAnchor(item), over: stage.page), on: stage)
        }
    }

    /// Its own bar button, under a page pushed over it: the bar shows the
    /// other page's.
    @Test func aBarButtonOfACoveredPageIsNotPointedAt() async throws {
        try await withStage { stage in
            let item = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.rightBarButtonItem = item
            stage.navigator.pushViewController(UIViewController(), animated: false)
            stage.window.layoutIfNeeded()

            let target = ShareSheet.popoverTarget(for: PopoverAnchor(item), over: stage.page)
            guard case .centre = target else {
                Issue.record("pointed at \(target)")
                return
            }
        }
    }

    @Test func aBarButtonOnTheLeftIsWhatThePopoverPointsAt() async throws {
        try await withStage { stage in
            let left = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.leftBarButtonItem = left
            stage.page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done)

            let popover = try pointedPopover(for: PopoverAnchor(left), over: stage.page)
            #expect(popover.barButtonItem === left)
            expectPointed(popover, on: stage)
        }
    }

    @Test func aHiddenBarButtonGivesWayToOneThatShows() async throws {
        try await withStage { stage in
            let hidden = UIBarButtonItem(systemItem: .action)
            hidden.isHidden = true
            let shown = UIBarButtonItem(systemItem: .done)
            stage.page.navigationItem.rightBarButtonItems = [hidden, shown]

            let popover = try pointedPopover(for: PopoverAnchor(hidden), over: stage.page)
            #expect(popover.barButtonItem === shown)
            expectPointed(popover, on: stage)
        }
    }

    @Test func aHiddenBarButtonAloneGivesWayToTheMiddleOfThePage() async throws {
        try await withStage { stage in
            let hidden = UIBarButtonItem(systemItem: .action)
            hidden.isHidden = true
            stage.page.navigationItem.rightBarButtonItem = hidden

            try expectCentred(pointedPopover(for: PopoverAnchor(hidden), over: stage.page), on: stage)
        }
    }

    @Test func aBarButtonThatIsGoneGivesWayToTheMiddleOfThePage() async throws {
        try await withStage { stage in
            var item: UIBarButtonItem? = UIBarButtonItem(systemItem: .action)
            let anchor = try PopoverAnchor(#require(item))
            item = nil
            #expect(anchor.barButtonItem == nil)

            try expectCentred(pointedPopover(for: anchor, over: stage.page), on: stage)
        }
    }

    // MARK: No anchor

    @Test func noAnchorPointsAtThePagesBarButton() async throws {
        try await withStage { stage in
            let item = UIBarButtonItem(systemItem: .action)
            stage.page.navigationItem.rightBarButtonItem = item

            let popover = try pointedPopover(for: nil, over: stage.page)
            #expect(popover.barButtonItem === item)
            expectPointed(popover, on: stage)
        }
    }

    @Test func noAnchorPointsAtTheRightBarButtonBeforeTheLeft() async throws {
        try await withStage { stage in
            let left = UIBarButtonItem(systemItem: .action)
            let right = UIBarButtonItem(systemItem: .done)
            stage.page.navigationItem.leftBarButtonItem = left

            let leftAlone = try pointedPopover(for: nil, over: stage.page)
            #expect(leftAlone.barButtonItem === left)

            stage.page.navigationItem.rightBarButtonItem = right
            let both = try pointedPopover(for: nil, over: stage.page)
            #expect(both.barButtonItem === right)
            expectPointed(both, on: stage)
        }
    }

    @Test func noAnchorAndNoBarButtonPointsAtTheMiddleOfThePage() async throws {
        try await withStage { stage in
            try expectCentred(pointedPopover(for: nil, over: stage.page), on: stage)
        }
    }

    /// The items of a bar nobody sees are nowhere to point.
    @Test func aHiddenNavigationBarsButtonsAreNotPointedAt() async throws {
        try await withStage { stage in
            stage.page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action)
            stage.navigator.setNavigationBarHidden(true, animated: false)

            try expectCentred(pointedPopover(for: nil, over: stage.page), on: stage)
        }
    }

    // MARK: A presenter nobody sees

    @Test func aPageWithNoNavigatorPointsAtItsOwnMiddle() throws {
        let page = UIViewController()
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action)

        let popover = try pointedPopover(for: nil, over: page)
        expectPointed(popover)
        expectCentred(popover, in: page.view)
    }

    /// A presenter in no window gets an answer a popover can take, and is
    /// never presented over: the answer points into no window.
    @Test func aPresenterWithNoWindowHasAnAnswerAndIsNotPresentedOver() async throws {
        try await withStage { stage in
            let page = UIViewController()
            page.loadViewIfNeeded()
            let popover = try pointedPopover(for: PopoverAnchor(button(on: stage)), over: page)
            expectPointed(popover)
            expectCentred(popover, in: page.view)
            #expect(popover.sourceView?.window == nil)
            #expect(!ShareSheet.canPresent(over: page))
        }
    }

    /// The decision is asked of a page and does not load it.
    @Test func thePagesViewIsNotLoadedToDecide() async throws {
        try await withStage { stage in
            let child = UIViewController()
            stage.page.addChild(child)
            child.didMove(toParent: stage.page)

            let target = ShareSheet.popoverTarget(for: nil, over: child)
            #expect(!child.isViewLoaded)
            guard case let .centre(view) = target else {
                Issue.record("pointed at \(target)")
                return
            }
            #expect(view === stage.page.view)
        }
    }

    // MARK: The sheet itself

    /// Through the function the app calls, on either device. The iPhone's
    /// sheet is no popover, so the decision is asked for there as well.
    @Test func theSheetAlwaysLeavesPointed() async throws {
        try await withStage { stage in
            let hidden = UIBarButtonItem(systemItem: .action)
            hidden.isHidden = true
            let anchors: [PopoverAnchor?] = [
                nil,
                PopoverAnchor(UIView()),
                PopoverAnchor(hidden),
                PopoverAnchor(UIBarButtonItem(systemItem: .done)),
                PopoverAnchor(button(on: stage)),
            ]

            for anchor in anchors {
                try expectPointed(pointedPopover(for: anchor, over: stage.page), on: stage)

                let sheet = ShareSheet.controller(["text"], anchor: anchor, over: stage.page)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    try expectPointed(#require(sheet.popoverPresentationController), on: stage)
                }
            }
        }
    }

    // MARK: The presenter

    @Test func aSheetGoesOverAPageThatCanTakeIt() async throws {
        try await withStage { stage in
            #expect(ShareSheet.canPresent(over: stage.page))
            #expect(ShareSheet.presentableController(for: stage.page) === stage.page)
            #expect(!ShareSheet.canPresent(over: UIViewController()))

            let loaded = UIViewController()
            loaded.loadViewIfNeeded()
            #expect(!ShareSheet.canPresent(over: loaded))
        }
    }

    /// Presented by the navigation controller the page is in, not by the
    /// page: the page can take nothing either.
    @Test func aPageWhoseAncestorPresentsCannotTakeASheet() async throws {
        try await withStage { stage in
            let child = UIViewController()
            stage.page.addChild(child)
            stage.page.view.addSubview(child.view)
            child.didMove(toParent: stage.page)
            #expect(ShareSheet.canPresent(over: child))

            stage.navigator.present(UIViewController(), animated: false)
            #expect(!ShareSheet.canPresent(over: child))
            #expect(!ShareSheet.canPresent(over: stage.page))
        }
    }

    /// A share that comes back to a page showing something else goes over
    /// that, and points there.
    @Test func aSheetGoesOverWhatThePageShows() async throws {
        try await withStage { stage in
            let item = UIBarButtonItem(systemItem: .action)
            let shown = UIViewController()
            shown.navigationItem.rightBarButtonItem = item
            let modal = UINavigationController(rootViewController: shown)
            stage.page.present(modal, animated: false)
            // on screen a turn of the run loop later, animated or not
            for _ in 0 ..< 50 where shown.viewIfLoaded?.window == nil {
                try await Task.sleep(for: .milliseconds(20))
            }

            #expect(ShareSheet.presentableController(for: stage.page) === shown)
            try expectPointed(pointedPopover(for: nil, over: shown))

            ShareSheet.present(["text"], anchor: PopoverAnchor(button(on: stage)), from: stage.page)
            for _ in 0 ..< 50 where shown.presentedViewController == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(stage.page.presentedViewController === modal)
            let sheet = try #require(shown.presentedViewController as? UIActivityViewController)
            if let popover = sheet.popoverPresentationController {
                expectPointed(popover)
                #expect(popover.sourceView !== stage.page.view)
            }
        }
    }

    /// A page that was popped has no window of its own; the anchor's is
    /// where the user was.
    @Test func aSheetFromAPageThatLeftGoesOverThePageOnTop() async throws {
        try await withStage { stage in
            let left = UIViewController()
            left.loadViewIfNeeded()
            let anchor = PopoverAnchor(button(on: stage))

            #expect(ShareSheet.presentableController(for: left, anchor: anchor) === stage.page)
        }
    }

    @Test func aCancelledTaskSharesNothing() async throws {
        try await withStage { stage in
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                ShareSheet.present(["text"], anchor: nil, from: stage.page)
            }
            await task.value
            #expect(stage.page.presentedViewController == nil)
        }
    }

    // MARK: The anchor

    @Test func anActionsSenderIsAnAnchorWhenItCanBePointedAt() {
        let view = UIView()
        let item = UIBarButtonItem(systemItem: .action)
        #expect(PopoverAnchor(sender: view)?.view === view)
        #expect(PopoverAnchor(sender: item)?.barButtonItem === item)
        #expect(PopoverAnchor(sender: nil) == nil)
        #expect(PopoverAnchor(sender: "a context menu") == nil)
    }
}
