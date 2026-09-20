@testable import irisin
import Testing
import UIKit

@MainActor
struct NamedImageTests {
    /// An image asked for by name is a string the compiler never checks: a
    /// rename that reaches the Swift and not the catalog draws nothing.
    @Test(arguments: ["RepositoryTableCell.Missing", "RepositoryTableCell.Right"])
    func theCatalogHasTheImage(name: String) {
        #expect(UIImage(named: name) != nil)
    }
}
