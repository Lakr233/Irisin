import Foundation

/// One filesystem change whose original contents must survive a failed unpack.
///
/// `installed` is the digest of what the transaction put at the destination
/// once it had, and `removed` says it deleted the file. A journal replayed
/// after a crash restores a destination only while it still holds that:
/// a file some later dpkg run rewrote in between is that run's to keep.
struct PackageFileBackup: Codable {
    let destination: URL
    let saved: URL?
    var installed: String?
    var removed = false
}

/// A journal line: one backup and where it belongs in the list, so that a
/// change to a record already written is another line rather than a rewrite
/// of the whole journal.
struct JournalRecord: Codable {
    let at: Int
    let backup: PackageFileBackup
}
