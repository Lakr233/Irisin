import ArchiveKit
import CryptoKit
import Foundation
import IrisinProtocol

/// A `.deb` decoded into the prepared tree `irisin-install` installs from:
/// `manifest.json` (a `PreparedPackage`) and one generated `blob-N` per
/// regular file and control member. libarchive never chooses an output
/// path: regular contents go into the flat blobs, links stay metadata.
///
/// The app runs this as `mobile` on what it downloaded (through
/// `ArchiveStream.prepareDebianPackage`, which reads a control file the way
/// apt prints one); the helper runs it as root only on a package an
/// external client submitted, which a client already trusted to install as
/// root, maintainer scripts and all, has handed it.
public enum DebianPreparation {
    /// Prepares `source` into `directory` and returns the SHA-256 of the
    /// manifest it wrote. `decodeControl` reads the control file's bytes;
    /// by default only UTF-8 is a control file.
    public static func prepare(
        at source: URL,
        in directory: URL,
        decodeControl: (Data) throws -> String = DebianPreparation.strictUTF8
    ) throws -> String {
        try withUTF8Names { try prepare(source, in: directory, decodeControl: decodeControl) }
    }

    /// UTF-8, or a refusal.
    public static func strictUTF8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// libarchive converts entry names into the calling thread's codeset,
    /// and a process that starts in the C locale fails a UTF-8 name in a PAX
    /// header. A UTF-8 LC_CTYPE on this thread only, restored after; never
    /// `setlocale`, which is process-wide.
    static func withUTF8Names<T>(_ body: () throws -> T) rethrows -> T {
        let previous = uselocale(nil)
        guard let base = duplocale(previous) else { return try body() }
        guard let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", base) else {
            freelocale(base)
            return try body()
        }
        uselocale(utf8)
        defer {
            uselocale(previous)
            freelocale(utf8)
        }
        return try body()
    }

    private static func prepare(
        _ source: URL,
        in directory: URL,
        decodeControl: (Data) throws -> String
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outer = try reader(source, tar: false)
        defer { archive_read_free(outer) }
        var header: OpaquePointer?
        var controls: [String: PreparedFile] = [:]
        var entries: [PreparedEntry] = []
        var members = Set<String>()
        var control = ""
        var sequence = 0
        while true {
            let status = archive_read_next_header(outer, &header)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK, let header, let pathname = archive_entry_pathname(header) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = String(cString: pathname)
            if name == "debian-binary" {
                guard members.insert(name).inserted else { throw CocoaError(.fileReadCorruptFile) }
                let blob = try copyMember(outer, directory: directory, sequence: &sequence)
                let version = try String(contentsOf: directory.appendingPathComponent(blob.name), encoding: .utf8)
                guard version == "2.0\n" else { throw CocoaError(.fileReadCorruptFile) }
                continue
            }
            let isControl = name == "control.tar" || name.hasPrefix("control.tar.")
            let isData = name == "data.tar" || name.hasPrefix("data.tar.")
            guard isControl || isData else { archive_read_data_skip(outer); continue }
            guard members.insert(isControl ? "control" : "data").inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let compressed = try copyMember(outer, directory: directory, sequence: &sequence)
            let inner = try reader(directory.appendingPathComponent(compressed.name), tar: true)
            defer { archive_read_free(inner) }
            var seen = Set<String>()
            var entry: OpaquePointer?
            while true {
                let status = archive_read_next_header(inner, &entry)
                if status == ARCHIVE_EOF {
                    break
                }
                guard status == ARCHIVE_OK, let entry, let pathname = archive_entry_pathname(entry) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let path = try PreparedPackage.relativePath(String(cString: pathname))
                if path.isEmpty {
                    archive_read_data_skip(inner); continue
                }
                guard seen.insert(path).inserted else { throw CocoaError(.fileReadCorruptFile) }
                let kind: PreparedEntry.Kind
                var file: PreparedFile?
                var link: String?
                if let target = archive_entry_hardlink(entry) {
                    kind = .hardLink
                    link = try PreparedPackage.relativePath(String(cString: target))
                } else {
                    switch archive_entry_filetype(entry) {
                    case UInt16(S_IFREG):
                        kind = .file; file = try copyMember(inner, directory: directory, sequence: &sequence)
                    case UInt16(S_IFDIR): kind = .directory
                    case UInt16(S_IFLNK):
                        kind = .symbolicLink
                        guard let target = archive_entry_symlink(entry) else { throw CocoaError(.fileReadCorruptFile) }
                        link = String(cString: target)
                    default: throw CocoaError(.fileReadUnsupportedScheme)
                    }
                }
                if isControl {
                    guard kind == .file, !path.utf8.contains(0x2F), let file else { throw CocoaError(.fileReadCorruptFile) }
                    controls[path] = file
                    if path == "control" {
                        control = try decodeControl(
                            Data(contentsOf: directory.appendingPathComponent(file.name))
                        )
                    }
                } else {
                    let owner = try owner(of: entry)
                    entries.append(PreparedEntry(
                        path: path,
                        kind: kind,
                        file: file,
                        linkTarget: link,
                        mode: UInt32(archive_entry_perm(entry)),
                        uid: owner.uid,
                        gid: owner.gid,
                        userName: owner.userName,
                        groupName: owner.groupName,
                        modificationTime: Int64(archive_entry_mtime(entry))
                    ))
                }
            }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(compressed.name))
        }
        guard members.isSuperset(of: ["debian-binary", "control", "data"]), !control.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = PreparedPackage(control: control, controlFiles: controls, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An entry's owner as the archive stores it, numbers and names both.
    /// Which wins is the helper's to say, against the bootstrap's accounts
    /// (`PackageOverrides.owner`): the app runs this as mobile, where only
    /// the system's accounts answer, and a name only the bootstrap has
    /// would have fallen back to its number.
    private static func owner(
        of entry: OpaquePointer
    ) throws -> (uid: UInt32, gid: UInt32, userName: String?, groupName: String?) {
        guard archive_entry_uid(entry) >= 0, archive_entry_uid(entry) <= Int64(UInt32.max),
              archive_entry_gid(entry) >= 0, archive_entry_gid(entry) <= Int64(UInt32.max)
        else { throw CocoaError(.fileReadCorruptFile) }
        func name(_ text: UnsafePointer<CChar>?) -> String? {
            guard let text, text.pointee != 0 else { return nil }
            return String(validatingCString: text)
        }
        return (
            UInt32(archive_entry_uid(entry)),
            UInt32(archive_entry_gid(entry)),
            name(archive_entry_uname(entry)),
            name(archive_entry_gname(entry))
        )
    }

    private static func reader(_ source: URL, tar: Bool) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw CocoaError(.fileReadUnknown) }
        archive_read_support_filter_all(archive)
        if tar {
            archive_read_support_format_tar(archive)
        } else {
            archive_read_support_format_ar(archive)
        }
        guard archive_read_open_filename(archive, source.path, 65536) == ARCHIVE_OK else {
            archive_read_free(archive)
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    private static func copyMember(
        _ archive: OpaquePointer,
        directory: URL,
        sequence: inout Int
    ) throws -> PreparedFile {
        sequence += 1
        let name = "blob-\(sequence)"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = archive_read_data(archive, &buffer, buffer.count)
            guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            if count == 0 {
                break
            }
            let data = Data(buffer.prefix(count))
            try file.write(contentsOf: data)
            sha.update(data: data)
            md5.update(data: data)
            total += Int64(count)
        }
        return PreparedFile(
            name: name,
            sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
            md5: md5.finalize().map { String(format: "%02x", $0) }.joined(),
            size: total
        )
    }
}
