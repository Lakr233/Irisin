@testable import irisin
import Testing
import UIKit

/// The iPad answers a popover with nowhere to point with an exception, so
/// whatever the anchor has become by the time the sheet is shown, the
/// popover must leave with a source view or a bar button.
@MainActor
struct ShareSheetAnchorTests {
    /// A page on screen: in a navigation controller, in a window.
    @MainActor
    private final class Stage {
        let window: UIWindow
        let navigator: UINavigationController
        let page = UIViewController()

        init?() {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first else { return nil }
            window = UIWindow(windowScene: scene)
            navigator = UINavigationController(rootViewController: page)
            window.rootViewController = navigator
            window.isHidden = false
            page.loadViewIfNeeded()
            window.layoutIfNeeded()
        }
    }

    /// A popover of the kind the share sheet has on the iPad, on any device.
    private func pointedPopover(
        for anchor: PopoverAnchor?,
        over presenter: UIViewController
    ) throws -> UIPopoverPresentationController {
        let content = UIViewController()
        content.modalPresentationStyle = .popover
        let popover = try #require(content.popoverPresentationController)
        InterfaceBridge.point(popover, at: InterfaceBridge.popoverTarget(for: anchor, over: presenter))
        return popover
    }

    private func expectPointed(_ popover: UIPopoverPresentationController) {
        #expect(popover.sourceView != nil || popover.barButtonItem != nil)
    }

    private func expectCentred(_ popover: UIPopoverPresentationController, in view: UIView) {
        #expect(popover.sourceView === view)
        #expect(popover.barButtonItem == nil)
        #expect(popover.permittedArrowDirections == [])
        #expect(popover.sourceRect.size == .zero)
        #expect(popover.sourceRect.origin == CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    // MARK: A view

    @Test func aViewOnScreenIsWhatThePopoverPointsAt() throws {
        let stage = try #require(Stage())
        let button = UIView(frame: CGRect(x: 10, y: 20, width: 44, height: 44))
        stage.page.view.addSubview(button)

        let popover = try pointedPopover(for: PopoverAnchor(button), over: stage.page)
        #expect(popover.sourceView === button)
        #expect(popover.sourceRect == button.bounds)
        expectPointed(popover)
    }

    /// A cell that scrolled away while the share waited on a download.
    @Test func aViewThatLeftItsWindowGivesWayToTheMiddleOfThePage() throws {
        let stage = try #require(Stage())
        let cell = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        stage.page.view.addSubview(cell)
        let anchor = PopoverAnchor(cell)
        cell.removeFromSuperview()

        let popover = try pointedPopover(for: anchor, over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    @Test func aViewThatIsGoneGivesWayToTheMiddleOfThePage() throws {
        let stage = try #require(Stage())
        var cell: UIView? = UIView()
        let anchor = try PopoverAnchor(#require(cell))
        cell = nil
        #expect(anchor.view == nil)

        let popover = try pointedPopover(for: anchor, over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    @Test func aViewThatLeftGivesWayToThePagesBarButton() throws {
        let stage = try #require(Stage())
        let pageItem = UIBarButtonItem(systemItem: .action)
        stage.page.navigationItem.rightBarButtonItem = pageItem
        let anchor = PopoverAnchor(UIView())

        let popover = try pointedPopover(for: anchor, over: stage.page)
        #expect(popover.barButtonItem === pageItem)
        expectPointed(popover)
    }

    // MARK: A bar button

    @Test func aBarButtonIsWhatThePopoverPointsAt() throws {
        let stage = try #require(Stage())
        let item = UIBarButtonItem(systemItem: .action)
        stage.page.navigationItem.rightBarButtonItem = item

        let popover = try pointedPopover(for: PopoverAnchor(item), over: stage.page)
        #expect(popover.barButtonItem === item)
        expectPointed(popover)
    }

    /// The bar button of a page that was popped while the download ran: not
    /// hidden, and nowhere.
    @Test func aBarButtonOfAnotherPageIsNotPointedAt() throws {
        let stage = try #require(Stage())
        let stranger = UIBarButtonItem(systemItem: .action)
        #expect(!stranger.isHidden)

        let alone = try pointedPopover(for: PopoverAnchor(stranger), over: stage.page)
        expectPointed(alone)
        expectCentred(alone, in: stage.page.view)

        let pageItem = UIBarButtonItem(systemItem: .done)
        stage.page.navigationItem.rightBarButtonItem = pageItem
        let beside = try pointedPopover(for: PopoverAnchor(stranger), over: stage.page)
        #expect(beside.barButtonItem === pageItem)
    }

    @Test func aBarButtonOfAHiddenBarIsNotPointedAt() throws {
        let stage = try #require(Stage())
        let item = UIBarButtonItem(systemItem: .action)
        stage.page.navigationItem.rightBarButtonItem = item
        stage.navigator.setNavigationBarHidden(true, animated: false)

        let popover = try pointedPopover(for: PopoverAnchor(item), over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    @Test func aBarButtonOnTheLeftIsWhatThePopoverPointsAt() throws {
        let stage = try #require(Stage())
        let left = UIBarButtonItem(systemItem: .action)
        stage.page.navigationItem.leftBarButtonItem = left
        stage.page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done)

        let popover = try pointedPopover(for: PopoverAnchor(left), over: stage.page)
        #expect(popover.barButtonItem === left)
    }

    @Test func aHiddenBarButtonGivesWayToOneThatShows() throws {
        let stage = try #require(Stage())
        let hidden = UIBarButtonItem(systemItem: .action)
        hidden.isHidden = true
        let shown = UIBarButtonItem(systemItem: .done)
        stage.page.navigationItem.rightBarButtonItems = [hidden, shown]

        let popover = try pointedPopover(for: PopoverAnchor(hidden), over: stage.page)
        #expect(popover.barButtonItem === shown)
        expectPointed(popover)
    }

    @Test func aHiddenBarButtonAloneGivesWayToTheMiddleOfThePage() throws {
        let stage = try #require(Stage())
        let hidden = UIBarButtonItem(systemItem: .action)
        hidden.isHidden = true
        stage.page.navigationItem.rightBarButtonItem = hidden

        let popover = try pointedPopover(for: PopoverAnchor(hidden), over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    @Test func aBarButtonThatIsGoneGivesWayToTheMiddleOfThePage() throws {
        let stage = try #require(Stage())
        var item: UIBarButtonItem? = UIBarButtonItem(systemItem: .action)
        let anchor = try PopoverAnchor(#require(item))
        item = nil
        #expect(anchor.barButtonItem == nil)

        let popover = try pointedPopover(for: anchor, over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    // MARK: No anchor

    @Test func noAnchorPointsAtThePagesBarButton() throws {
        let stage = try #require(Stage())
        let item = UIBarButtonItem(systemItem: .action)
        stage.page.navigationItem.rightBarButtonItem = item

        let popover = try pointedPopover(for: nil, over: stage.page)
        #expect(popover.barButtonItem === item)
        expectPointed(popover)
    }

    @Test func noAnchorPointsAtTheRightBarButtonBeforeTheLeft() throws {
        let stage = try #require(Stage())
        let left = UIBarButtonItem(systemItem: .action)
        let right = UIBarButtonItem(systemItem: .done)
        stage.page.navigationItem.leftBarButtonItem = left

        let leftAlone = try pointedPopover(for: nil, over: stage.page)
        #expect(leftAlone.barButtonItem === left)

        stage.page.navigationItem.rightBarButtonItem = right
        let both = try pointedPopover(for: nil, over: stage.page)
        #expect(both.barButtonItem === right)
    }

    @Test func noAnchorAndNoBarButtonPointsAtTheMiddleOfThePage() throws {
        let stage = try #require(Stage())

        let popover = try pointedPopover(for: nil, over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    /// The items of a bar nobody sees are nowhere to point.
    @Test func aHiddenNavigationBarsButtonsAreNotPointedAt() throws {
        let stage = try #require(Stage())
        stage.page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action)
        stage.navigator.setNavigationBarHidden(true, animated: false)

        let popover = try pointedPopover(for: nil, over: stage.page)
        expectPointed(popover)
        expectCentred(popover, in: stage.page.view)
    }

    @Test func aPageWithNoNavigatorPointsAtItsOwnMiddle() throws {
        let page = UIViewController()
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action)

        let popover = try pointedPopover(for: nil, over: page)
        expectPointed(popover)
        expectCentred(popover, in: page.view)
    }

    /// A presenter in no window at all still gets a popover that can be
    /// asked to begin.
    @Test func aPresenterWithNoWindowStillHasSomewhereToPoint() throws {
        let page = UIViewController()
        let popover = try pointedPopover(for: PopoverAnchor(UIView()), over: page)
        expectPointed(popover)
        expectCentred(popover, in: page.view)
    }

    // MARK: The sheet itself

    /// Every state above, through the function the app calls. The iPhone's
    /// sheet is no popover and has nothing to point.
    @Test func theSheetAlwaysLeavesPointed() throws {
        let stage = try #require(Stage())
        let detached = UIView()
        let hidden = UIBarButtonItem(systemItem: .action)
        hidden.isHidden = true
        let anchors: [PopoverAnchor?] = [nil, PopoverAnchor(detached), PopoverAnchor(hidden)]

        for anchor in anchors {
            let sheet = InterfaceBridge.shareSheet(["text"], anchor: anchor, over: stage.page)
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                continue
            }
            let popover = try #require(sheet.popoverPresentationController)
            expectPointed(popover)
        }
    }

    // MARK: The presenter

    /// A share that comes back from a download to a page that left, or that
    /// shows something else by then, is dropped.
    @Test func aSheetIsPresentedOnlyOverAPageThatCanTakeIt() throws {
        let stage = try #require(Stage())
        #expect(InterfaceBridge.canPresent(over: stage.page))
        #expect(!InterfaceBridge.canPresent(over: UIViewController()))

        let loaded = UIViewController()
        loaded.loadViewIfNeeded()
        #expect(!InterfaceBridge.canPresent(over: loaded))

        stage.page.present(UIViewController(), animated: false)
        #expect(stage.page.presentedViewController != nil)
        #expect(!InterfaceBridge.canPresent(over: stage.page))
        InterfaceBridge.presentShareSheet(["text"], anchor: nil, from: stage.page)
        #expect(!(stage.page.presentedViewController is UIActivityViewController))
        stage.page.dismiss(animated: false)
    }

    // MARK: The anchor

    @Test func anActionsSenderIsAnAnchorWhenItCanBePointedAt() throws {
        let view = UIView()
        let item = UIBarButtonItem(systemItem: .action)
        #expect(PopoverAnchor(sender: view)?.view === view)
        #expect(PopoverAnchor(sender: item)?.barButtonItem === item)
        #expect(PopoverAnchor(sender: nil) == nil)
        #expect(PopoverAnchor(sender: "a context menu") == nil)
    }
}
