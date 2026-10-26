/// A RootHide bootstrap's root, told by its name the way libroothide tells it
/// (`is_jbroot_name`, which its `init.c` applies to its own image path):
/// `.jbroot-` and sixteen hex digits, the last byte the xor of the seven
/// before it. The app, the daemon and the helper read this one rule.
public enum RoothideRoot {
    private static let prefix = ".jbroot-"

    /// Whether `name`, one path component, names a RootHide root. Digits
    /// only: a sign is a number to `UInt64` and to `strtoull`, and no name
    /// RootHide makes.
    public static func isRootName(_ name: some StringProtocol) -> Bool {
        let digits = name.dropFirst(prefix.count)
        guard name.hasPrefix(prefix), digits.count == 16, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16)
        else { return false }
        let check = (1 ... 7).reduce(UInt8(0)) { $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8)) }
        return check == UInt8(truncatingIfNeeded: value)
    }

    /// The RootHide root `path` lies in: its components up to and including
    /// the first that names one, or nil. The path is read as spelled:
    /// resolving it could only lose the name being looked for.
    public static func root(ofPath path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { isRootName($0) }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }
}
