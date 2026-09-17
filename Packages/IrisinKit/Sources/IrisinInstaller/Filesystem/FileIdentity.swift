import Darwin
import Foundation

/// A file that is not a directory, as the kernel knows it from `lstat`: two
/// paths with the same device and inode are one file, as dpkg's
/// `file_ondisk_id` has it.
struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}
