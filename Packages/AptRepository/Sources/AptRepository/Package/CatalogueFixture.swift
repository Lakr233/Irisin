import Foundation

/// A catalogue written from index files on disk, for the tools under
/// `Tools/` that measure the resolver against real repositories without a
/// network: each text goes through the same parse and the same database
/// write a refresh does. Nothing in the app calls it.
@_spi(Probe)
public enum CatalogueFixture {
    /// Reads one repository's Packages text, several indexes joined by a
    /// blank line as a suite's are, and puts its packages in the
    /// catalogue in place of the ones it had. Returns how many identities
    /// it offers.
    @discardableResult
    public static func store(index text: String, of repository: URL) -> Int {
        let packages = invokePackages(withContext: text, fromRepo: repository)
        AptDatabase.shared.replacePackages(of: repository, with: packages)
        return packages.count
    }
}
