//
//  Debian version strings, `[epoch:]upstream[-revision]`, parsed and ordered
//  the way Debian Policy §5.6.12 describes: epochs numerically, then the
//  upstream part, then the revision, each as alternating runs of non-digits
//  and digits, `~` sorting before everything including the end.
//

import Foundation

public enum DebianVersion {
    public typealias Parsed = (epoch: Int, upstream: Substring, revision: Substring)

    /// The three parts, or nil when the string is not a version dpkg would
    /// accept: empty, embedded whitespace, a non-numeric or empty epoch,
    /// nothing after the colon, or an empty revision after the hyphen. A
    /// character outside `A-Za-z0-9.+~` only earns a warning from dpkg, so
    /// it is accepted here too and ordered by its code point.
    public static func parse(_ string: String) -> Parsed? {
        let text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        var epoch = 0
        var rest = text
        if let colon = text.firstIndex(of: ":") {
            // dpkg reads the epoch with strtol, which takes a leading plus
            var digits = text[..<colon]
            if digits.first == "+" {
                digits = digits.dropFirst()
            }
            // dpkg keeps the epoch in an int and refuses one that does not fit
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let value = Int(digits),
                  value <= Int(Int32.max) else { return nil }
            epoch = value
            rest = text[text.index(after: colon)...]
            guard !rest.isEmpty else { return nil }
        }

        var upstream = rest
        var revision: Substring = ""
        if let hyphen = rest.lastIndex(of: "-") {
            upstream = rest[..<hyphen]
            revision = rest[rest.index(after: hyphen)...]
            guard !revision.isEmpty else { return nil }
        }
        guard !upstream.isEmpty else { return nil }
        return (epoch, upstream, revision)
    }

    public static func isValid(_ string: String) -> Bool {
        parse(string) != nil
    }

    /// The version as dpkg writes it back (`versiondescribe` with
    /// `vdew_nonambig`): surrounding whitespace gone, a zero epoch omitted
    /// unless a colon elsewhere would make the rest ambiguous, a leading
    /// plus on the epoch dropped. Nil when the string is not a version.
    public static func canonical(_ string: String) -> String? {
        guard let parsed = parse(string) else { return nil }
        var text = ""
        if parsed.epoch != 0 || parsed.upstream.contains(":") || parsed.revision.contains(":") {
            text = "\(parsed.epoch):"
        }
        text += parsed.upstream
        if !parsed.revision.isEmpty {
            text += "-" + parsed.revision
        }
        return text
    }

    /// Negative when `a` sorts before `b`, positive after, zero when equal.
    /// Two strings that are not both valid compare equal, as the C wrapper
    /// this replaces did.
    public static func compare(_ a: String, _ b: String) -> Int {
        guard let a = parse(a), let b = parse(b) else { return 0 }
        return compare(a, b)
    }

    /// The order of two parsed versions, for a caller that parsed once and
    /// compares many times.
    public static func compare(_ a: Parsed, _ b: Parsed) -> Int {
        if a.epoch != b.epoch {
            return a.epoch < b.epoch ? -1 : 1
        }
        let upstream = compareFragment(a.upstream, b.upstream)
        if upstream != 0 {
            return upstream
        }
        return compareFragment(a.revision, b.revision)
    }

    /// The weight of one character in a non-digit run: `~` before the end
    /// of the string, then letters, then everything else by code point. A
    /// digit met while the other side is still in its non-digit run weighs
    /// the same as the end, so `1.0` sorts before `1.0a` and `0~2022`
    /// before `0~bzr`.
    private static func weight(_ character: Character?) -> Int {
        guard let character, !character.isASCIIDigit else { return 0 }
        if character == "~" {
            return -1
        }
        if character.isASCIILetter {
            return Int(character.asciiValue!)
        }
        return Int(character.unicodeScalars.first!.value) + 256
    }

    private static func compareFragment(_ a: Substring, _ b: Substring) -> Int {
        var a = a[...]
        var b = b[...]
        while !a.isEmpty || !b.isEmpty {
            // the non-digit run
            while (a.first.map { !$0.isASCIIDigit } ?? false) || (b.first.map { !$0.isASCIIDigit } ?? false) {
                let difference = weight(a.first) - weight(b.first)
                if difference != 0 {
                    return difference
                }
                a = a.dropFirst()
                b = b.dropFirst()
            }
            // the digit run, without leading zeros
            a = a.drop { $0 == "0" }
            b = b.drop { $0 == "0" }
            var firstDifference = 0
            while let ca = a.first, let cb = b.first, ca.isASCIIDigit, cb.isASCIIDigit {
                if firstDifference == 0 {
                    firstDifference = Int(ca.asciiValue!) - Int(cb.asciiValue!)
                }
                a = a.dropFirst()
                b = b.dropFirst()
            }
            if a.first?.isASCIIDigit ?? false {
                return 1
            }
            if b.first?.isASCIIDigit ?? false {
                return -1
            }
            if firstDifference != 0 {
                return firstDifference
            }
        }
        return 0
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        guard let value = asciiValue else { return false }
        return value >= 48 && value <= 57
    }

    var isASCIILetter: Bool {
        guard let value = asciiValue else { return false }
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }
}
