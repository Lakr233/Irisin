import CoreGraphics
@testable import irisin
import Testing
import UIKit

@MainActor
struct OperationWarningBannerTests {
    /// A table header is frame-sized. Its red content must fill that frame
    /// horizontally while the header alone supplies the vertical spacing.
    @Test func bannerIsFullWidthWithVerticalPadding() throws {
        let header = OperationWarningBanner(title: "Recovery Mode")
        let width: CGFloat = 390
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        header.frame = CGRect(origin: .zero, size: size)
        header.layoutIfNeeded()

        let banner = try #require(header.subviews.first)
        #expect(size.width == width)
        #expect(banner.frame.minX == 0)
        #expect(banner.frame.maxX == width)
        #expect(abs(banner.frame.minY - 12) < 0.001)
        #expect(abs(header.bounds.maxY - banner.frame.maxY - 12) < 0.001)
    }
}
