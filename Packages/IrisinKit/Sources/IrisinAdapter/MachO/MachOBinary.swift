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
    /// A library or an rpath the patcher's shell reads otherwise than it is
    /// written (a control byte, a backslash, a blank at its edge), so that
    /// install_name_tool would be asked to change a name that is not there.
    case unsupportedName
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
    /// Whether the patcher runs install_name_tool on the file, which writes
    /// it anew as root: it does for any name it reads off otool that starts
    /// with `/var/jb/`, whether or not that changes anything (a library's
    /// own name, a dependency cut at a space). ldid alone keeps the file's
    /// owner and mode.
    let installNameToolRuns: Bool

    /// nil for a file that is not a Mach-O. A library, a bundle or a
    /// program, 64-bit in every slice and sound enough to rewrite, or
    /// `MachOFailure`.
    init?(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else {
            // `file` calls four bytes of a thin magic a Mach-O, and ldid
            // then fails on it; a fat magic it calls text
            if data.count >= 4, [MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64].contains(data.integer(at: 0) as UInt32) {
                throw MachOFailure.malformed
            }
            return nil
        }
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
        let contents = data
        installNameToolRuns = try slices.flatMap { try Self.names(in: $0, contents) }.map(Self.patcherChanges).contains(true)
    }

    /// A load command that names a library or an rpath.
    private struct LoadCommandName {
        enum Kind { case rpath, dependency, id }
        let kind: Kind
        /// Where the command is among the commands, and its length.
        let offset: Int, size: Int
        /// Where the name starts in the command.
        let start: Int
        let bytes: [UInt8]
    }

    private static func names(in slice: Slice, _ data: Data) throws -> [LoadCommandName] {
        try slice.file.loadCommands.compactMap { command in
            let (kind, offset, size, start): (LoadCommandName.Kind, Int, Int, UInt32)
            switch command {
            case let .rpath(rpath):
                (kind, offset, size, start) = (.rpath, rpath.offset, Int(rpath.layout.cmdsize), rpath.layout.path.offset)
            case let .loadDylib(dylib), let .loadWeakDylib(dylib), let .reexportDylib(dylib),
                 let .lazyLoadDylib(dylib), let .loadUpwardDylib(dylib):
                (kind, offset, size, start) = (.dependency, dylib.offset, Int(dylib.layout.cmdsize), dylib.layout.dylib.name.offset)
            case let .idDylib(dylib):
                (kind, offset, size, start) = (.id, dylib.offset, Int(dylib.layout.cmdsize), dylib.layout.dylib.name.offset)
            default:
                return nil
            }
            guard start >= 12, start < size else { throw MachOFailure.malformed }
            let command = slice.range.lowerBound + MemoryLayout<mach_header_64>.size + offset
            let bytes = data[command + Int(start) ..< command + size].prefix { $0 != 0 }
            return LoadCommandName(kind: kind, offset: offset, size: size, start: Int(start), bytes: Array(bytes))
        }
    }

    /// Whether the patcher asks install_name_tool to change `name`. It reads
    /// the name off otool through `read`, which drops blanks at the edges
    /// and the backslash of every escape, a dependency after `cut -d' '
    /// -f1` and `tr -d '[:blank:]'`, and asks when what comes out starts
    /// with `/var/jb/`. What comes out otherwise than it went in would
    /// change another name or none, and is refused.
    private static func patcherChanges(_ name: LoadCommandName) throws -> Bool {
        // a control byte splits otool's line, or is a tab tr drops
        guard !name.bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { throw MachOFailure.unsupportedName }
        let read = name.bytes.drop { $0 == 0x20 }.filter { $0 != 0x5C }
        guard read.starts(with: "/var/jb/".utf8) else { return false }
        // a space later in a dependency is cut away with the rest of the
        // line, and the change asked for then matches nothing, as `rewrite`
        // leaves it
        guard name.bytes.first != 0x20, !name.bytes.contains(0x5C), name.kind != .rpath || name.bytes.last != 0x20 else {
            throw MachOFailure.unsupportedName
        }
        return true
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

        var signature: LoadCommandInfo<linkedit_data_command>?
        // ldid sets the size of every `__LINKEDIT` there is
        var linkedits: [SegmentCommand64] = []
        // where the string table ends, where ldid ends the code: the last
        // LC_SYMTAB's, unless that one is all zeros
        var strings: UInt64?
        // ldid's executable segment: from the first byte of any segment
        // that maps code to the last, in its own unsigned arithmetic
        var executable: (start: UInt64, end: UInt64) = (.max, 0)
        // the last `__info_plist` of any `__TEXT` segment: its file offset
        // and size, as ldid finds it
        var infoPlist: (offset: UInt64, size: UInt64)?
        // Where a segment that holds content without sections begins.
        // `install_name_tool` counts these when it measures the room in
        // front of the file, and so must anything that writes there.
        // Offsets stay 64-bit: MachOKit's `Int` of one past 2^63 traps.
        var sectionlessContent: [UInt64] = []
        for command in slice.file.loadCommands {
            switch command {
            case let .codeSignature(info):
                signature = info
            case let .symtab(symtab):
                let (offset, size) = (symtab.layout.stroff, symtab.layout.strsize)
                strings = offset == 0 && size == 0 ? nil : UInt64(offset) + UInt64(size)
            case let .segment64(segment):
                if segment.segmentName == SEG_LINKEDIT {
                    linkedits.append(segment)
                }
                if segment.layout.initprot & VM_PROT_EXECUTE != 0 {
                    executable = (min(executable.start, segment.layout.fileoff), max(executable.end, segment.layout.fileoff &+ segment.layout.filesize))
                }
                if segment.segmentName == SEG_TEXT {
                    for section in segment.sections(in: slice.file) where section.sectionName == "__info_plist" {
                        infoPlist = (segment.layout.fileoff &+ UInt64(section.layout.offset), section.layout.size)
                    }
                }
                if segment.numberOfSections == 0, segment.layout.filesize > 0 {
                    sectionlessContent.append(segment.layout.fileoff)
                }
            default:
                break
            }
        }
        guard !linkedits.isEmpty else { throw MachOFailure.malformed }

        // what changes, in file order: (offset among the commands, old length, new bytes)
        var replacements: [(offset: Int, size: Int, bytes: Data)] = []
        for name in try Self.names(in: slice, data) where name.kind != .id && name.bytes.starts(with: "/var/jb/".utf8) {
            // a dependency with a space in it is cut short, and matches nothing
            if name.kind == .dependency, name.bytes.contains(0x20) {
                continue
            }
            let start = headerSize + name.offset
            var bytes = Data(image[start ..< start + name.start])
            bytes.append(contentsOf: "@loader_path/.jbroot/".utf8)
            bytes.append(contentsOf: name.bytes.dropFirst("/var/jb/".utf8.count))
            bytes.append(Data(count: (bytes.count + 1).aligned(to: 8) - bytes.count))
            bytes.store(UInt32(bytes.count), at: 4)
            replacements.append((name.offset, name.size, bytes))
        }

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

        // the old signature begins where the code ended; a file that never
        // had one gets the command, as ldid adds it, after all the others
        let oldSignature: Int
        let signatureCommand: Int
        if let signature {
            oldSignature = Int(signature.layout.dataoff)
            guard oldSignature <= image.count, oldSignature + Int(signature.layout.datasize) == image.count else { throw MachOFailure.malformed }
            signatureCommand = moved(signature.offset)
        } else {
            oldSignature = image.count
            signatureCommand = headerSize + commands.count
            var command = Data(count: MemoryLayout<linkedit_data_command>.size)
            command.store(UInt32(LC_CODE_SIGNATURE), at: 0)
            command.store(UInt32(command.count), at: 4)
            commands.append(command)
            image.store(slice.file.header.ncmds + 1, at: 16)
        }
        // ldid ends the code at the end of the string table, which it adds
        // up in 32 bits and asserts is not past the old signature
        var codeEnd = oldSignature
        if let strings {
            guard strings <= UInt32.max, strings <= UInt64(codeEnd) else { throw MachOFailure.malformed }
            codeEnd = Int(strings)
        }
        let content = slice.file.sections64.map { UInt64($0.layout.offset) } + sectionlessContent
        let firstSection = content.filter { $0 > 0 }.min() ?? 0
        guard UInt64(headerSize + commands.count) <= firstSection, firstSection <= UInt64(codeEnd) else { throw MachOFailure.noRoom }
        image.replaceSubrange(headerSize ..< headerSize + commands.count, with: commands)
        image.store(UInt32(commands.count), at: 20)

        var signer = LdidStyleSignature(identifier: identifier)
        if isProgram {
            // each slice keeps its own, read before the old signature goes
            var entitlements = try LdidEntitlements(xml: signature == nil ? Data() : Self.entitlements(in: Data(image[oldSignature...])))
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
        // ldid rounds the segment to the slice's alignment in the fat header,
        // or in a thin file to what it takes its CPU's page to be
        let align = if let arch = slice.arch {
            Int(arch.align)
        } else {
            switch slice.file.header.cputype {
            case CPU_TYPE_ARM, CPU_TYPE_ARM64, CPU_TYPE_ARM64_32: 14
            case CPU_TYPE_X86, CPU_TYPE_X86_64, CPU_TYPE_POWERPC, CPU_TYPE_POWERPC64: 12
            default: 0
            }
        }
        for linkedit in linkedits {
            let end = UInt64(codeLimit + signatureSize)
            guard linkedit.layout.fileoff < end else { throw MachOFailure.malformed }
            let size = Int(end - linkedit.layout.fileoff)
            image.store(UInt64(size.aligned(to: 1 << align)), at: moved(linkedit.offset) + 32)
            image.store(UInt64(size), at: moved(linkedit.offset) + 48)
        }

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
            case UInt32(LC_SYMTAB):
                MemoryLayout<symtab_command>.size
            case UInt32(LC_ID_DYLIB), UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB:
                MemoryLayout<dylib_command>.size
            default:
                8
            }
            guard length >= least, length % 8 == 0, cursor + length <= size else { throw MachOFailure.malformed }
            if command == UInt32(LC_SEGMENT_64) {
                let sections = Int(data.integer(at: start + 64) as UInt32)
                guard least + sections * MemoryLayout<section_64>.size <= length else { throw MachOFailure.malformed }
                // install_name_tool refuses a segment past the end of its file
                let (offset, size) = (data.integer(at: start + 40) as UInt64, data.integer(at: start + 48) as UInt64)
                guard offset <= UInt64(range.count), size <= UInt64(range.count) - offset else { throw MachOFailure.malformed }
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
