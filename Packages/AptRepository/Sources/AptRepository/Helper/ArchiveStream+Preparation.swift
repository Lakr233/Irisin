import Foundation
import IrisinPreparation

extension ArchiveStream {
    /// Decode on the unprivileged side. Never let libarchive choose output
    /// paths: regular contents go into generated flat blobs, links stay
    /// metadata. `DebianPreparation` does the work, shared with the helper;
    /// the control file is read as apt prints one (`IndexText`).
    public static func prepareDebianPackage(at source: URL, in directory: URL) throws -> String {
        try DebianPreparation.prepare(at: source, in: directory) { IndexText.decode($0) }
    }
}
