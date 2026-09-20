import Darwin

/// Reads a descriptor to EOF and hands back each line as it completes: the
/// helper reading its tools and the app reading the helper are the same loop.
public enum LineReader {
    public static func read(descriptor: Int32, line: (String) -> Void) {
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0 ..< count])
            while let newline = pending.firstIndex(of: 0x0A) {
                line(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty {
            line(String(decoding: pending, as: UTF8.self))
        }
    }
}
