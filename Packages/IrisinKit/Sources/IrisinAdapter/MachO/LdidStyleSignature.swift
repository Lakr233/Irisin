import CryptoKit
import Foundation

/// The embedded signature `ldid -Hsha256 -S` leaves, which is what
/// roothide's patcher runs on every Mach-O it touched and what the device
/// accepts: a SuperBlob of a SHA-256 CodeDirectory and the designated
/// requirement ldid derives from the identifier, and for a program the
/// entitlements `-M -S<file>` merged, as XML and as DER. No CMS blob. The
/// layout was measured on the tool's output and the fixtures hold it to
/// that byte for byte; the hashing is CryptoKit's.
struct LdidStyleSignature {
    private static let pageSize = 4096
    private static let directoryHeaderSize = 88

    /// What ldid signs under: the name of the file.
    let identifier: String
    /// A program's merged entitlements (`LdidEntitlements`); nil for a
    /// library or a bundle, which ldid signs with none.
    var entitlements: (xml: Data, der: Data)?
    /// `__TEXT,__info_plist`, which ldid hashes into the info slot of
    /// whatever carries one.
    var infoPlist: Data?
    var executableSegmentFlags: UInt64 = 0

    init(identifier: String) {
        self.identifier = identifier
    }

    /// The signature's length for a slice whose code ends at `codeLimit`,
    /// known before anything is hashed: the load commands carry it and are
    /// themselves hashed.
    func size(codeLimit: Int) -> Int {
        let blobs = blobs()
        return 12 + 8 * (1 + blobs.count) + directorySize(codeLimit: codeLimit, specialSlots: specialSlots)
            + blobs.reduce(0) { $0 + $1.bytes.count }
    }

    /// `code` is the slice up to the signature, load commands final.
    /// `executable` is the executable segment as ldid records it: where the
    /// first segment that maps code starts in the file and how far the last
    /// one reaches past that.
    func blob(code: Data, executable: (base: UInt64, limit: UInt64)) -> Data {
        let blobs = blobs()
        let pages = stride(from: 0, to: code.count, by: Self.pageSize).map {
            code.subdata(in: $0 ..< min($0 + Self.pageSize, code.count))
        }
        let identifierBytes = Data(identifier.utf8) + [0]
        let hashOffset = Self.directoryHeaderSize + identifierBytes.count + specialSlots * SHA256.byteCount

        var directory = Data()
        directory.append(0xFADE_0C02 as UInt32)
        directory.append(UInt32(directorySize(codeLimit: code.count, specialSlots: specialSlots)))
        directory.append(0x20400 as UInt32) // version: the one with an executable segment
        directory.append(0 as UInt32) // flags: none, where Apple's ad-hoc signature says adhoc
        directory.append(UInt32(hashOffset))
        directory.append(UInt32(Self.directoryHeaderSize)) // identifier
        directory.append(UInt32(specialSlots))
        directory.append(UInt32(pages.count))
        directory.append(UInt32(code.count))
        directory.append(contentsOf: [UInt8(SHA256.byteCount), 2, 0, 12]) // hash size, SHA-256, platform, log2(page)
        directory.append(0 as UInt32) // spare2
        directory.append(0 as UInt32) // scatter
        directory.append(0 as UInt32) // team identifier
        directory.append(0 as UInt32) // spare3
        directory.append(0 as UInt64) // 64-bit code limit
        directory.append(executable.base)
        directory.append(executable.limit)
        directory.append(executableSegmentFlags)
        directory.append(identifierBytes)
        // the special slots count down to the info slot, in front of the pages
        for slot in (1 ... specialSlots).reversed() {
            let hashed = slot == 1 ? infoPlist : blobs.first { $0.slot == slot }?.bytes
            directory.append(hashed.map { Data(SHA256.hash(data: $0)) } ?? Data(count: SHA256.byteCount))
        }
        for page in pages {
            directory.append(Data(SHA256.hash(data: page)))
        }

        let all = [(slot: 0, bytes: directory)] + blobs
        var blob = Data()
        blob.append(0xFADE_0CC0 as UInt32)
        blob.append(UInt32(12 + 8 * all.count + all.reduce(0) { $0 + $1.bytes.count }))
        blob.append(UInt32(all.count))
        var offset = 12 + 8 * all.count
        for (slot, bytes) in all {
            blob.append(UInt32(slot))
            blob.append(UInt32(offset))
            offset += bytes.count
        }
        return all.reduce(blob) { $0 + $1.bytes }
    }

    /// Requirements, then a program's entitlements as XML and as DER, each
    /// under its slot: the order ldid lays them out in.
    private func blobs() -> [(slot: Int, bytes: Data)] {
        var blobs = [(slot: 2, bytes: Self.requirements(identifier: identifier))]
        if let entitlements {
            blobs.append((5, Self.wrapped(0xFADE_7171, entitlements.xml)))
            blobs.append((7, Self.wrapped(0xFADE_7172, entitlements.der)))
        }
        return blobs
    }

    /// The highest slot anything is in: the requirements', or the DER's.
    private var specialSlots: Int {
        entitlements == nil ? 2 : 7
    }

    private func directorySize(codeLimit: Int, specialSlots: Int) -> Int {
        Self.directoryHeaderSize + identifier.utf8.count + 1
            + (specialSlots + (codeLimit + Self.pageSize - 1) / Self.pageSize) * SHA256.byteCount
    }

    private static func wrapped(_ magic: UInt32, _ content: Data) -> Data {
        var blob = Data()
        blob.append(magic)
        blob.append(UInt32(8 + content.count))
        return blob + content
    }

    /// `identifier "<identifier>" and anchor apple generic and certificate
    /// leaf[subject.CN] = "" and certificate 1[field.1.2.840.113635.100.6.2.1]`,
    /// compiled: what ldid writes for every file, the identifier the only
    /// part that varies.
    private static func requirements(identifier: String) -> Data {
        func padded(_ bytes: some Sequence<UInt8>) -> Data {
            let data = Data(bytes)
            return data + Data(count: (4 - data.count % 4) % 4)
        }
        var expression = Data()
        expression.append(6 as UInt32) // and
        expression.append(2 as UInt32) // identifier
        expression.append(UInt32(identifier.utf8.count))
        expression.append(padded(identifier.utf8))
        expression.append(6 as UInt32) // and
        expression.append(15 as UInt32) // anchor apple generic
        expression.append(6 as UInt32) // and
        expression.append(11 as UInt32) // certificate field
        expression.append(0 as UInt32) // leaf
        expression.append(10 as UInt32)
        expression.append(padded("subject.CN".utf8))
        expression.append(1 as UInt32) // equal
        expression.append(0 as UInt32) // to the empty string
        expression.append(14 as UInt32) // certificate generic
        expression.append(1 as UInt32) // the one above the leaf
        expression.append(10 as UInt32)
        expression.append(padded([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01]))
        expression.append(0 as UInt32) // exists

        var requirements = Data()
        requirements.append(0xFADE_0C01 as UInt32)
        requirements.append(UInt32(20 + 12 + expression.count))
        requirements.append(1 as UInt32)
        requirements.append(3 as UInt32) // designated
        requirements.append(20 as UInt32)
        requirements.append(0xFADE_0C00 as UInt32)
        requirements.append(UInt32(12 + expression.count))
        requirements.append(1 as UInt32) // an expression
        return requirements + expression
    }
}

private extension Data {
    /// Code signing structures are big-endian whatever the slice is.
    mutating func append(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
