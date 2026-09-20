import CAptArchive
import Foundation
import IrisinProtocol

/// libarchive over the shapes this app reads: a compressed repository
/// index, the `control` member of a `.deb`, and a `.deb`'s listing.
///
/// One library for every filter (gzip, bzip2, xz, lzma, zstd, lz4) and the
/// two containers involved (`ar` outside a package, `tar` inside), instead of
/// a Swift decoder per format and a hand-written `ar` walker.
public enum ArchiveStream {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private static let chunkSize = 64 * 1024

    /// The bytes behind any compression filter libarchive knows, or the input
    /// unchanged when it carries none.
    public static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { bytes -> Data in
            let archive = try open(filters: true, formats: [archive_read_support_format_raw])
            defer { archive_read_free(archive) }
            try check(archive_read_open_memory(archive, bytes.baseAddress, bytes.count), archive)
            var entry: OpaquePointer?
            try check(archive_read_next_header(archive, &entry), archive)
            return try readData(archive)
        }
    }

    /// The `control` file of a Debian package on disk, read without unpacking
    /// anything else: the outer `ar` is walked to its `control.tar.*` member,
    /// which is small and is opened as a second archive from memory.
    public static func debianControl(atPath path: String) throws -> String {
        let outer = try open(filters: false, formats: [archive_read_support_format_ar])
        defer { archive_read_free(outer) }
        try check(archive_read_open_filename(outer, path, chunkSize), outer)
        var entry: OpaquePointer?
        while archive_read_next_header(outer, &entry) == ARCHIVE_OK {
            guard let name = archive_entry_pathname(entry).map({ String(cString: $0) }),
                  name.hasPrefix("control.tar")
            else {
                archive_read_data_skip(outer)
                continue
            }
            let member = try readData(outer)
            return try member.withUnsafeBytes { bytes -> String in
                let inner = try open(filters: true, formats: [archive_read_support_format_tar])
                defer { archive_read_free(inner) }
                try check(archive_read_open_memory(inner, bytes.baseAddress, bytes.count), inner)
                var file: OpaquePointer?
                while archive_read_next_header(inner, &file) == ARCHIVE_OK {
                    let name = archive_entry_pathname(file).map { String(cString: $0) } ?? ""
                    guard name == "control" || name == "./control" else {
                        archive_read_data_skip(inner)
                        continue
                    }
                    return try String(decoding: readData(inner), as: UTF8.self)
                }
                throw Failure(description: "control.tar has no control file")
            }
        }
        throw Failure(description: "not a Debian package: no control.tar member")
    }

    /// What a Debian package on disk holds, read without writing anything:
    /// the members of `control.tar` dpkg knows and the paths of `data.tar`.
    public struct DebianContents: Sendable {
        /// `control`, the maintainer scripts, `conffiles`, by member name. A
        /// script may be a binary, so these are bytes.
        public let controlFiles: [String: Data]
        /// What the package installs that is not a directory, spelled as
        /// dpkg lists it: absolute.
        public let files: [String]
        public let directories: [String]
    }

    /// The control members the installer opens by name, and the only ones
    /// read here: `PackageTransaction` runs the four scripts and parses
    /// `conffiles` and `triggers`; anything else (`config`, `extrainst_`,
    /// `md5sums`) it copies into dpkg's info directory unopened. A package
    /// may pack as much of that as it likes, so none of it is held.
    private static let controlMembers: Set<String> = [
        "control", "preinst", "postinst", "prerm", "postrm", "conffiles", "triggers",
    ]

    /// One of those larger than this is not read either: nothing shows a
    /// script that long, and the size is the package's own word.
    private static let controlMemberLimit: Int64 = 1 << 20

    /// The listing of a Debian package. Both inner archives are streamed out
    /// of the outer `ar`, so a large `data.tar` is decoded and never held.
    public static func debianContents(atPath path: String) throws -> DebianContents {
        let outer = try open(filters: false, formats: [archive_read_support_format_ar])
        defer { archive_read_free(outer) }
        try check(archive_read_open_filename(outer, path, chunkSize), outer)
        var controlFiles: [String: Data] = [:]
        var files: [String] = []
        var directories: [String] = []
        var members = Set<String>()
        var header: OpaquePointer?
        while archive_read_next_header(outer, &header) == ARCHIVE_OK {
            let name = archive_entry_pathname(header).map { String(cString: $0) } ?? ""
            let isControl = name == "control.tar" || name.hasPrefix("control.tar.")
            let isData = name == "data.tar" || name.hasPrefix("data.tar.")
            guard isControl || isData, members.insert(isControl ? "control" : "data").inserted else {
                archive_read_data_skip(outer)
                continue
            }
            let inner = try open(filters: true, formats: [archive_read_support_format_tar])
            defer { archive_read_free(inner) }
            let member = Member(outer: outer)
            try check(
                archive_read_open(inner, Unmanaged.passUnretained(member).toOpaque(), nil, { _, client, buffer in
                    guard let client else { return -1 }
                    let member = Unmanaged<Member>.fromOpaque(client).takeUnretainedValue()
                    buffer?.pointee = UnsafeRawPointer(member.buffer)
                    return archive_read_data(member.outer, member.buffer, ArchiveStream.chunkSize)
                }, nil),
                inner
            )
            try withExtendedLifetime(member) {
                var entry: OpaquePointer?
                while true {
                    let status = archive_read_next_header(inner, &entry)
                    if status == ARCHIVE_EOF {
                        break
                    }
                    try check(status, inner)
                    let relative = try PreparedPackage.relativePath(
                        archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
                    )
                    if relative.isEmpty {
                        continue
                    }
                    if isControl {
                        if controlMembers.contains(relative), archive_entry_size(entry) <= controlMemberLimit {
                            controlFiles[relative] = try readData(inner)
                        }
                    } else if archive_entry_filetype(entry) == UInt16(S_IFDIR) {
                        directories.append("/" + relative)
                    } else {
                        files.append("/" + relative)
                    }
                }
            }
        }
        guard members == ["control", "data"] else {
            throw Failure(description: "not a Debian package: control.tar or data.tar is missing")
        }
        return DebianContents(controlFiles: controlFiles, files: files, directories: directories)
    }

    /// The `ar` member the outer archive stands at, as the bytes of an
    /// archive of its own. libarchive reads the buffer until it asks again.
    private final class Member {
        let outer: OpaquePointer
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: ArchiveStream.chunkSize, alignment: 1)

        init(outer: OpaquePointer) {
            self.outer = outer
        }

        deinit {
            buffer.deallocate()
        }
    }

    // MARK: - libarchive

    private static func open(filters: Bool, formats: [(OpaquePointer?) -> Int32]) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw Failure(description: "archive_read_new failed") }
        if filters {
            archive_read_support_filter_all(archive)
        }
        for format in formats {
            _ = format(archive)
        }
        return archive
    }

    private static func readData(_ archive: OpaquePointer) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count < 0 {
                throw Failure(description: message(archive))
            }
            if count == 0 {
                break
            }
            output.append(buffer, count: count)
        }
        return output
    }

    private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status == ARCHIVE_OK else { throw Failure(description: message(archive)) }
    }

    private static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
    }
}
