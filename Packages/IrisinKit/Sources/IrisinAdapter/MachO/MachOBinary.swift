import Foundation
import MachOKit

/// Why a Mach-O cannot be rewritten. `RootlessToRoothide` turns each into
/// the `AdaptationFailure` the app spells.
enum MachOFailure: Error, Equatable {
    /// A slice that is not a library, a bundle or a program: an object
    /// file, a dSYM, anything stranger. Not what a package installs to run.
    case notCode
    /// A header, an architecture, a load command or the old signature
    /// points outside the file.
    case malformed
    /// A program whose entitlements ldid would not carry over as they are
    /// read here: a binary plist, a date or a real (which ldid refuses), XML
    /// libplist reads its own way, a list Foundation would write otherwise
    /// than libplist but for the order of its keys (`LdidEntitlements`).
    case unsupportedEntitlements
    /// A slice that is not 64-bit little-endian. The patcher's tools would
    /// rewrite and sign an armv7 slice as well; nothing a roothide device
    /// loads has one, so the package is refused instead.
    case unsupportedSlice
    /// The longer load commands do not fit in front of the first section.
    case noRoom
}

/// One Mach-O of a package, thin or fat, and what roothide's patcher does
/// to it: every `/var/jb/` rpath and dependency becomes
/// `@loader_path/.jbroot/`, the way `install_name_tool` writes it, and
/// every slice is signed again the way `ldid -Hsha256 -S` signs it, or for
/// a program `ldid -Hsha256 -M -S<roothide.entitlements>`: its own
/// entitlements with roothide's merged in.
///
/// MachOKit says where a load command is and what it holds. It maps the
/// file and trusts what it reads, so the bounds are checked here first, and
/// it writes nothing: the bytes that change are changed below.
struct MachOBinary {
    private struct Slice {
        let file: MachOFile
        let range: Range<Int>
        let arch: fat_arch?
    }

    private let data: Data
    private let slices: [Slice]
    /// What `file` says of the whole file, which is what the patcher asks
    /// before it picks ldid's arguments: a program if any slice is one.
    private let isProgram: Bool

    /// nil for a file that is not a Mach-O. A library, a bundle or a
    /// program, 64-bit in every slice and sound enough to rewrite, or
    /// `MachOFailure`.
    init?(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else { return nil }
        let magic: UInt32 = data.integer(at: 0)
        switch magic {
        case MH_MAGIC_64:
            try Self.checkType(data, at: 0)
            try Self.validate(data, 0 ..< data.count)
            guard case let .machO(file) = try MachOKit.loadFromFile(url: url) else { throw MachOFailure.malformed }
            slices = [Slice(file: file, range: 0 ..< data.count, arch: nil)]
        case MH_MAGIC:
            try Self.checkType(data, at: 0)
            throw MachOFailure.unsupportedSlice
        case MH_CIGAM, MH_CIGAM_64, FAT_CIGAM_64:
            throw MachOFailure.unsupportedSlice
        case FAT_CIGAM:
            // a Java class opens with the same four bytes, so `file` calls
            // the file a Mach-O only under 20 architectures, and the patcher
            // leaves any other alone
            let count = Int((data.integer(at: 4) as UInt32).byteSwapped)
            guard (1 ..< 20).contains(count) else { return nil }
            guard 8 + count * MemoryLayout<fat_arch>.size <= data.count,
                  case let .fat(fat) = try MachOKit.loadFromFile(url: url)
            else { throw MachOFailure.malformed }
            let arches = fat.arches.map(\.layout)
            for arch in arches {
                // `lipo` writes no alignment above 2^15, and one slice per
                // exponent above that is another gigabyte of padding to lay
                // the file out again in memory
                guard arch.align <= 15, Int(arch.offset) + Int(arch.size) <= data.count else { throw MachOFailure.malformed }
            }
            // what the file is before whether it can be rewritten: a dSYM
            // with an armv7 slice is a dSYM
            for arch in arches {
                try Self.checkType(data, at: Int(arch.offset))
            }
            for arch in arches {
                try Self.validate(data, Int(arch.offset) ..< Int(arch.offset) + Int(arch.size))
            }
            slices = try zip(fat.machOFiles(), arches).map { file, arch in
                Slice(file: file, range: Int(arch.offset) ..< Int(arch.offset) + Int(arch.size), arch: arch)
            }
        default:
            return nil
        }
        isProgram = slices.contains { $0.file.header.filetype == UInt32(MH_EXECUTE) }
    }

    /// The file as the patcher leaves it. `identifier` is what ldid signs
    /// under: the name of the file, whatever the signature it replaces said.
    func rewritten(identifier: String) throws -> Data {
        let images = try slices.map { try rewrite($0, identifier: identifier) }
        guard slices[0].arch != nil else { return images[0] }

        // ldid lays the slices out again, each on its own alignment
        var header = Data()
        header.append(bigEndian: FAT_MAGIC)
        header.append(bigEndian: UInt32(slices.count))
        var body = Data()
        let bodyStart = 8 + slices.count * MemoryLayout<fat_arch>.size
        for (slice, image) in zip(slices, images) {
            let arch = slice.arch!
            let offset = (bodyStart + body.count).aligned(to: 1 << Int(arch.align))
            body.append(Data(count: offset - bodyStart - body.count))
            body.append(image)
            // a fat header counts in 32 bits, so a file this size has none
            guard let start = UInt32(exactly: offset), let size = UInt32(exactly: image.count) else {
                throw MachOFailure.malformed
            }
            for field in [UInt32(bitPattern: arch.cputype), UInt32(bitPattern: arch.cpusubtype), start, size, arch.align] {
                header.append(bigEndian: field)
            }
        }
        return header + body
    }

    private func rewrite(_ slice: Slice, identifier: String) throws -> Data {
        let headerSize = MemoryLayout<mach_header_64>.size
        var image = Data(data[slice.range])
        let commandsSize = Int(slice.file.header.sizeofcmds)

        // what changes, in file order: (offset among the commands, old length, new bytes)
        var replacements: [(offset: Int, size: Int, bytes: Data)] = []
        var signature: LoadCommandInfo<linkedit_data_command>?
        var linkedit: SegmentCommand64?
        // ldid's executable segment: from the first byte of any segment
        // that maps code to the last, in its own unsigned arithmetic
        var executable: (start: UInt64, end: UInt64) = (.max, 0)
        // the last `__info_plist` of any `__TEXT` segment: its file offset
        // and size, as ldid finds it
        var infoPlist: (offset: UInt64, size: UInt64)?
        // Where a segment that holds content without sections begins.
        // `install_name_tool` counts these when it measures the room in
        // front of the file, and so must anything that writes there.
        var sectionlessContent: [Int] = []
        for command in slice.file.loadCommands {
            let path: (offset: Int, size: Int, name: Int)
            switch command {
            case let .rpath(rpath):
                path = (rpath.offset, Int(rpath.layout.cmdsize), Int(rpath.layout.path.offset))
            case let .loadDylib(dylib), let .loadWeakDylib(dylib), let .reexportDylib(dylib),
                 let .lazyLoadDylib(dylib), let .loadUpwardDylib(dylib):
                path = (dylib.offset, Int(dylib.layout.cmdsize), Int(dylib.layout.dylib.name.offset))
            case let .codeSignature(info):
                signature = info
                continue
            case let .segment64(segment):
                if segment.segmentName == SEG_LINKEDIT {
                    linkedit = segment
                }
                if segment.layout.initprot & VM_PROT_EXECUTE != 0 {
                    executable = (min(executable.start, segment.layout.fileoff), max(executable.end, segment.layout.fileoff &+ segment.layout.filesize))
                }
                if segment.segmentName == SEG_TEXT {
                    for section in segment.sections(in: slice.file) where section.sectionName == "__info_plist" {
                        infoPlist = (segment.layout.fileoff &+ UInt64(section.layout.offset), section.layout.size)
                    }
                }
                if segment.numberOfSections == 0, segment.fileSize > 0 {
                    sectionlessContent.append(segment.fileOffset)
                }
                continue
            default:
                continue
            }
            guard path.name >= 12, path.name < path.size else { throw MachOFailure.malformed }
            let start = headerSize + path.offset
            let name = image[start + path.name ..< start + path.size].prefix { $0 != 0 }
            guard let old = String(data: name, encoding: .utf8), old.hasPrefix("/var/jb/") else { continue }
            // the patcher reads dependencies off `otool -L` and cuts each
            // line at its first space, so one with a space never matches
            if case .rpath = command {} else if old.contains(" ") {
                continue
            }
            var bytes = Data(image[start ..< start + path.name])
            bytes.append(contentsOf: ("@loader_path/.jbroot/" + old.dropFirst("/var/jb/".count)).utf8)
            bytes.append(Data(count: (bytes.count + 1).aligned(to: 8) - bytes.count))
            bytes.store(UInt32(bytes.count), at: 4)
            replacements.append((path.offset, path.size, bytes))
        }
        guard let linkedit else { throw MachOFailure.malformed }

        var commands = Data()
        var cursor = 0
        for replacement in replacements {
            commands.append(image[headerSize + cursor ..< headerSize + replacement.offset])
            commands.append(replacement.bytes)
            cursor = replacement.offset + replacement.size
        }
        commands.append(image[headerSize + cursor ..< headerSize + commandsSize])
        /// Where a command that was at `offset` among the commands is now, in the image.
        func moved(_ offset: Int) -> Int {
            headerSize + offset + replacements.filter { $0.offset < offset }.reduce(0) { $0 + $1.bytes.count - $1.size }
        }

        // the code ends where the old signature began; a file that never
        // had one gets the command, as ldid adds it, after all the others
        let codeEnd: Int
        let signatureCommand: Int
        if let signature {
            codeEnd = Int(signature.layout.dataoff)
            guard codeEnd <= image.count, codeEnd + Int(signature.layout.datasize) == image.count else { throw MachOFailure.malformed }
            signatureCommand = moved(signature.offset)
        } else {
            codeEnd = image.count
            signatureCommand = headerSize + commands.count
            var command = Data(count: MemoryLayout<linkedit_data_command>.size)
            command.store(UInt32(LC_CODE_SIGNATURE), at: 0)
            command.store(UInt32(command.count), at: 4)
            commands.append(command)
            image.store(slice.file.header.ncmds + 1, at: 16)
        }
        let content = slice.file.sections64.map { Int($0.layout.offset) } + sectionlessContent
        let firstSection = content.filter { $0 > 0 }.min() ?? 0
        guard headerSize + commands.count <= firstSection, firstSection <= codeEnd else { throw MachOFailure.noRoom }
        image.replaceSubrange(headerSize ..< headerSize + commands.count, with: commands)
        image.store(UInt32(commands.count), at: 20)

        var signer = LdidStyleSignature(identifier: identifier)
        if isProgram {
            // each slice keeps its own, read before the old signature goes
            var entitlements = try LdidEntitlements(xml: signature == nil ? Data() : Self.entitlements(in: Data(image[codeEnd...])))
            entitlements.merge(LdidEntitlements.roothide)
            signer.entitlements = try (entitlements.xml(), entitlements.der)
            signer.executableSegmentFlags = entitlements.executableSegmentFlags(
                mainBinary: slice.file.header.filetype == UInt32(MH_EXECUTE)
            )
        }
        // ldid hashes it in the file it was given, at an offset it cuts to
        // 32 bits: that file is this one, old signature and all, but for the
        // signature command it adds itself, so a section over the commands
        // is refused
        if let infoPlist {
            let start = Int(UInt32(truncatingIfNeeded: infoPlist.offset))
            guard start >= headerSize + commands.count, start <= image.count, infoPlist.size <= UInt64(image.count - start) else {
                throw MachOFailure.malformed
            }
            signer.infoPlist = image.subdata(in: start ..< start + Int(infoPlist.size))
        }

        let codeLimit = codeEnd.aligned(to: 16)
        let signatureSize = signer.size(codeLimit: codeLimit).aligned(to: 16)
        image = image.prefix(codeEnd) + Data(count: codeLimit - codeEnd)
        image.store(UInt32(codeLimit), at: signatureCommand + 8)
        image.store(UInt32(signatureSize), at: signatureCommand + 12)
        let linkeditSize = codeLimit + signatureSize - linkedit.fileOffset
        guard linkeditSize > 0 else { throw MachOFailure.malformed }
        // ldid rounds the segment to the slice's own page size, which is 16K
        // only where the kernel's is: arm64 and arm64e
        let pageSize = slice.file.header.cputype == CPU_TYPE_ARM64 ? 0x4000 : 0x1000
        image.store(UInt64(linkeditSize.aligned(to: pageSize)), at: moved(linkedit.offset) + 32)
        image.store(UInt64(linkeditSize), at: moved(linkedit.offset) + 48)

        let blob = signer.blob(code: image, executable: (executable.start, executable.end &- executable.start))
        return image + blob + Data(count: signatureSize - blob.count)
    }

    /// The XML in the old signature's entitlements slot, as ldid reads it:
    /// the last blob of that type, nothing where there is none, and the
    /// SuperBlob's own magic unread.
    private static func entitlements(in signature: Data) throws -> Data {
        guard signature.count >= 12 else { throw MachOFailure.malformed }
        let count = Int(signature.bigEndianInteger(at: 8) as UInt32)
        guard 12 + count * 8 <= signature.count else { throw MachOFailure.malformed }
        var found = Data()
        for index in 0 ..< count where signature.bigEndianInteger(at: 12 + index * 8) as UInt32 == 5 {
            let offset = Int(signature.bigEndianInteger(at: 16 + index * 8) as UInt32)
            guard offset + 8 <= signature.count else { throw MachOFailure.malformed }
            let length = Int(signature.bigEndianInteger(at: offset + 4) as UInt32)
            guard length >= 8, offset + length <= signature.count else { throw MachOFailure.malformed }
            found = signature.subdata(in: offset + 8 ..< offset + length)
        }
        return found
    }

    /// `filetype` sits at the same offset in either header; a slice that is
    /// not a little-endian Mach-O at all is `validate`'s to refuse.
    private static func checkType(_ data: Data, at offset: Int) throws {
        guard offset + 16 <= data.count else { throw MachOFailure.malformed }
        let magic: UInt32 = data.integer(at: offset)
        guard magic == MH_MAGIC || magic == MH_MAGIC_64 else { return }
        let type: UInt32 = data.integer(at: offset + 12)
        guard [MH_DYLIB, MH_BUNDLE, MH_EXECUTE].map(UInt32.init).contains(type) else { throw MachOFailure.notCode }
    }

    /// What MachOKit is about to take on trust: a 64-bit header, and load
    /// commands that stay inside the space the header gives them.
    private static func validate(_ data: Data, _ range: Range<Int>) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard range.count >= headerSize else { throw MachOFailure.malformed }
        guard data.integer(at: range.lowerBound) as UInt32 == MH_MAGIC_64 else { throw MachOFailure.unsupportedSlice }
        let count = Int(data.integer(at: range.lowerBound + 16) as UInt32)
        let size = Int(data.integer(at: range.lowerBound + 20) as UInt32)
        guard headerSize + size <= range.count else { throw MachOFailure.malformed }
        var cursor = 0
        for _ in 0 ..< count {
            guard cursor + 8 <= size else { throw MachOFailure.malformed }
            let start = range.lowerBound + headerSize + cursor
            let command: UInt32 = data.integer(at: start)
            let length = Int(data.integer(at: start + 4) as UInt32)
            let least = switch command {
            case UInt32(LC_SEGMENT_64):
                MemoryLayout<segment_command_64>.size
            case UInt32(LC_CODE_SIGNATURE):
                MemoryLayout<linkedit_data_command>.size
            case UInt32(LC_RPATH):
                MemoryLayout<rpath_command>.size
            case UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB:
                MemoryLayout<dylib_command>.size
            default:
                8
            }
            guard length >= least, length % 8 == 0, cursor + length <= size else { throw MachOFailure.malformed }
            if command == UInt32(LC_SEGMENT_64) {
                let sections = Int(data.integer(at: start + 64) as UInt32)
                guard least + sections * MemoryLayout<section_64>.size <= length else { throw MachOFailure.malformed }
            }
            cursor += length
        }
    }
}

private extension Int {
    func aligned(to boundary: Int) -> Int {
        (self + boundary - 1) / boundary * boundary
    }
}

private extension Data {
    /// A Mach-O field, little-endian as every slice that gets here is.
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    /// A code signing field, big-endian whatever the slice is.
    func bigEndianInteger<T: FixedWidthInteger>(at offset: Int) -> T {
        T(bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    mutating func store(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset ..< offset + $0.count, with: $0) }
    }

    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
