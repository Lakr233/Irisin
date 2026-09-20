import Darwin
import Dispatch

/// Ends the old daemon after its executable is replaced or removed.
///
/// dpkg renames a new file over the old one. The running image remains valid,
/// but its opened inode eventually loses its last name. Watching that inode,
/// rather than the path, distinguishes replacement/removal from an unrelated
/// directory change. The registration check closes the race between `open`
/// and kqueue registration.
final class ExecutableWatch: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let onUnlinked: @Sendable () -> Void

    init?(path: String, queue: DispatchQueue, onUnlinked: @escaping @Sendable () -> Void) {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
        self.onUnlinked = onUnlinked
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .link, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.checkLinkCount() }
        source.setRegistrationHandler { [weak self] in self?.checkLinkCount() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    private func checkLinkCount() {
        guard !source.isCancelled else { return }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_nlink == 0 else { return }
        source.cancel()
        onUnlinked()
    }
}
