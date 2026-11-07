import ArchiveKit
import Darwin
import Foundation
import IrisinProtocol

/// One tar member of a `.deb`, `control.tar.zst` or `data.tar.zst`, written the
/// way the bootstraps' own packages are: GNU tar through zstd, every name
/// below `./`. `DebianPreparation` reads what this writes.
///
/// A `PreparedEntry` says what goes in the header, relative path and all;
/// its `file` is not read. The empty path is the archive's own `./`.
public final class DebianTarWriter {
    /// On Procursus's golang-1.22-src, 12% larger than level 19 in a thirtieth
    /// of the time and 40% of the memory, which a phone feels more.
    private static let compressionLevel = "9"

    private var archive: OpaquePointer?
    private let entry: OpaquePointer

    public init(writingTo url: URL) throws {
        guard let archive = archive_write_new(), let entry = archive_entry_new() else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.archive = archive
        self.entry = entry
        guard archive_write_set_format_gnutar(archive) == ARCHIVE_OK,
              // ARCHIVE_WARN here is libarchive falling back on a `zstd`
              // program, which a device does not have
              archive_write_add_filter_zstd(archive) == ARCHIVE_OK,
              archive_write_set_filter_option(archive, "zstd", "compression-level", Self.compressionLevel) == ARCHIVE_OK,
              // a file holds the stream as it ended: padding the last block
              // is for tapes
              archive_write_set_bytes_in_last_block(archive, 1) == ARCHIVE_OK,
              archive_write_open_filename(archive, url.path) == ARCHIVE_OK
        else {
            throw Self.failure(archive)
        }
    }

    deinit {
        if let archive {
            archive_write_free(archive)
        }
        archive_entry_free(entry)
    }

    /// The entry's header. A regular file's `size` bytes follow through
    /// `write`; fewer are padded with zeros, and more are refused.
    public func begin(_ item: PreparedEntry, size: Int64 = 0) throws {
        guard let archive else { throw CocoaError(.fileWriteUnknown) }
        archive_entry_clear(entry)
        let name = item.path.isEmpty ? "./" : "./" + item.path + (item.kind == .directory ? "/" : "")
        archive_entry_set_pathname(entry, name)
        archive_entry_set_perm(entry, mode_t(item.mode))
        archive_entry_set_uid(entry, Int64(item.uid))
        archive_entry_set_gid(entry, Int64(item.gid))
        if let name = item.userName {
            archive_entry_set_uname(entry, name)
        }
        if let name = item.groupName {
            archive_entry_set_gname(entry, name)
        }
        archive_entry_set_mtime(entry, Int(item.modificationTime), 0)
        switch item.kind {
        case .file:
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_size(entry, size)
        case .directory:
            archive_entry_set_filetype(entry, UInt32(S_IFDIR))
        case .symbolicLink:
            archive_entry_set_filetype(entry, UInt32(S_IFLNK))
            archive_entry_set_symlink(entry, item.linkTarget)
        case .hardLink:
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_hardlink(entry, "./" + (item.linkTarget ?? ""))
        }
        guard archive_write_header(archive, entry) == ARCHIVE_OK else { throw Self.failure(archive) }
    }

    /// `begin` for a member whose bytes are at hand.
    public func add(_ item: PreparedEntry, contents: Data) throws {
        try begin(item, size: Int64(contents.count))
        try contents.withUnsafeBytes { try write($0) }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let archive else { throw CocoaError(.fileWriteUnknown) }
        var offset = 0
        while offset < bytes.count {
            let written = archive_write_data(archive, bytes.baseAddress! + offset, bytes.count - offset)
            guard written > 0 else { throw Self.failure(archive) }
            offset += written
        }
    }

    /// Ends the archive. Nothing is on disk whole until this returns.
    public func finish() throws {
        guard let archive else { return }
        self.archive = nil
        defer { archive_write_free(archive) }
        guard archive_write_close(archive) == ARCHIVE_OK else { throw Self.failure(archive) }
    }

    private static func failure(_ archive: OpaquePointer) -> Error {
        let text = archive_error_string(archive).map { String(cString: $0) }
        return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedFailureReasonErrorKey: text ?? "libarchive"])
    }
}

/// The `ar` a `.deb` is: `debian-binary`, then control, then data, which is
/// the order dpkg insists on, each header as `dpkg_ar_member_put_header`
/// writes one.
public enum DebianPackageWriter {
    /// `time` stands for when each member was made: a package repacked twice
    /// from the same files is the same package, byte for byte.
    public static func write(control: URL, data: URL, time: Int64, to descriptor: Int32) throws {
        try put(Data("!<arch>\n".utf8), to: descriptor)
        let version = Data("2.0\n".utf8)
        try put(header("debian-binary", size: Int64(version.count), time: time), to: descriptor)
        try put(version, to: descriptor)
        for member in [control, data] {
            let file = try FileHandle(forReadingFrom: member)
            defer { try? file.close() }
            let size = try Int64(file.seekToEnd())
            try file.seek(toOffset: 0)
            try put(header(member.lastPathComponent, size: size, time: time), to: descriptor)
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                try put(chunk, to: descriptor)
            }
            if size % 2 == 1 {
                try put(Data("\n".utf8), to: descriptor)
            }
        }
    }

    private static func header(_ name: String, size: Int64, time: Int64) -> Data {
        func field(_ text: String, _ width: Int) -> String {
            text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        return Data((
            field(name, 16) + field(String(time), 12) + field("0", 6) + field("0", 6)
                + field("100644", 8) + field(String(size), 10) + "`\n"
        ).utf8)
    }

    private static func put(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
    }
}
