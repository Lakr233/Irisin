import AptRepository
import Foundation

extension Package {
    /// Has a file already, local or cached. The cache is only a hint here;
    /// `Downloads` hashes the file before trusting it.
    var isOnDisk: Bool {
        fileOnDisk != nil
    }

    /// That file, for whoever only reads or copies it.
    var fileOnDisk: URL? {
        if let localFileURL {
            return localFileURL
        }
        guard let cached = Downloads.shared.completedFiles[obtainDownloadLink()],
              FileManager.default.fileExists(atPath: cached.path)
        else { return nil }
        return cached
    }
}
