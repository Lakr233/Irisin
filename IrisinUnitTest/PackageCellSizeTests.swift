import CoreGraphics
@testable import irisin
import Testing

@MainActor
struct PackageCellSizeTests {
    /// A page whose view is narrower than its own insets asks with a
    /// negative width, and the flow layout asserts on a negative size.
    @Test(arguments: [-40, -1, 0, 0.5] as [CGFloat])
    func aWidthThePageDoesNotHaveStillMakesACell(width: CGFloat) {
        let layout = PackageCell.layout(inWidth: width)
        #expect(layout.size.width == PackageCell.minimumSize.width)
        #expect(layout.size.height >= PackageCell.minimumSize.height)
        #expect(layout.itemsPerRow == 1)
    }

    @Test func aWideColumnIsCutIntoSeveralCells() {
        let layout = PackageCell.layout(inWidth: 1000)
        #expect(layout.itemsPerRow > 1)
        #expect(layout.size.width > 0)
        #expect(layout.size.width <= 280)
    }

    /// The columns are counted by a loop with a limit of its own: a width
    /// no screen has must reach it.
    @Test(arguments: [.infinity, .greatestFiniteMagnitude, .nan, -.infinity] as [CGFloat])
    func aWidthNoScreenHasStillMakesACell(width: CGFloat) {
        let layout = PackageCell.layout(inWidth: width)
        #expect(layout.itemsPerRow >= 1)
        #expect(layout.itemsPerRow <= 11)
    }
}
