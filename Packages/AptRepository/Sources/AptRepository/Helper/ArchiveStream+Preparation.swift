import CAptArchive
import CryptoKit
import Foundation
import IrisinProtocol

extension ArchiveStream {
    /// Decode on the unprivileged side. Never let libarchive choose output
    /// paths: regular contents go into generated flat blobs, links stay metadata.
    public static func prepareDebianPackage(at source: URL, in directory: URL) throws -> String {
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
            guard status == ARCHIVE_OK, let header else { throw CocoaError(.fileReadCorruptFile) }
            let name = String(cString: archive_entry_pathname(header))
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
                guard status == ARCHIVE_OK, let entry else { throw CocoaError(.fileReadCorruptFile) }
                let path = try PreparedPackage.relativePath(String(cString: archive_entry_pathname(entry)))
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
                        control = try IndexText.decode(
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
        return ResolutionSnapshot.digest(data)
    }

    /// An entry's owner as dpkg reads it: a user or group name this system
    /// knows wins over the number stored beside it. A package packed on a
    /// Mac without `--root-owner-group` says `root` next to its builder's
    /// uid, and dpkg installs it as root.
    private static func owner(of entry: OpaquePointer) throws -> (uid: UInt32, gid: UInt32) {
        guard archive_entry_uid(entry) >= 0, archive_entry_uid(entry) <= Int64(UInt32.max),
              archive_entry_gid(entry) >= 0, archive_entry_gid(entry) <= Int64(UInt32.max)
        else { throw CocoaError(.fileReadCorruptFile) }
        var uid = UInt32(archive_entry_uid(entry))
        var gid = UInt32(archive_entry_gid(entry))
        var buffer = [CChar](repeating: 0, count: 4096)
        if let name = archive_entry_uname(entry), name.pointee != 0 {
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            if getpwnam_r(name, &record, &buffer, buffer.count, &found) == 0, found != nil {
                uid = record.pw_uid
            }
        }
        if let name = archive_entry_gname(entry), name.pointee != 0 {
            var record = group()
            var found: UnsafeMutablePointer<group>?
            if getgrnam_r(name, &record, &buffer, buffer.count, &found) == 0, found != nil {
                gid = record.gr_gid
            }
        }
        return (uid, gid)
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
