import Darwin

/// A NULL-terminated `char *[]` for `posix_spawn`, freed when it goes away.
final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[count] = nil
    }

    deinit {
        for index in 0 ..< count {
            free(pointers[index])
        }
        pointers.deallocate()
    }
}
