import CryptoKit
import Foundation

/// The embedded signature `ldid -Hsha256 -S` leaves on a library or a
/// bundle, which is what roothide's patcher runs on every Mach-O it touched
/// and what the device accepts: a SuperBlob of a SHA-256 CodeDirectory and
/// the designated requirement ldid derives from the identifier. No
/// entitlements and no CMS blob. The layout was measured on the tool's
/// output and the fixtures hold it to that byte for byte; the hashing is
/// CryptoKit's.
enum LdidStyleSignature {
    private static let pageSize = 4096
    private static let directoryHeaderSize = 88

    /// The signature's length for a slice whose code ends at `codeLimit`,
    /// known before anything is hashed: the load commands carry it and are
    /// themselves hashed.
    static func size(identifier: String, codeLimit: Int) -> Int {
        12 + 2 * 8 + directorySize(identifier: identifier, codeLimit: codeLimit)
            + requirements(identifier: identifier).count
    }

    /// `code` is the slice up to the signature, load commands final.
    /// `text` is where the `__TEXT` segment lies in the file.
    static func blob(identifier: String, code: Data, text: (offset: Int, size: Int)) -> Data {
        let requirements = requirements(identifier: identifier)
        let pages = stride(from: 0, to: code.count, by: pageSize).map {
            code.subdata(in: $0 ..< min($0 + pageSize, code.count))
        }
        let identifierBytes = Data(identifier.utf8) + [0]
        let hashOffset = directoryHeaderSize + identifierBytes.count + 2 * SHA256.byteCount

        var directory = Data()
        directory.append(0xFADE_0C02 as UInt32)
        directory.append(UInt32(directorySize(identifier: identifier, codeLimit: code.count)))
        directory.append(0x20400 as UInt32) // version: the one with an executable segment
        directory.append(0 as UInt32) // flags: none, where Apple's ad-hoc signature says adhoc
        directory.append(UInt32(hashOffset))
        directory.append(UInt32(directoryHeaderSize)) // identifier
        directory.append(2 as UInt32) // special slots: info (unused), requirements
        directory.append(UInt32(pages.count))
        directory.append(UInt32(code.count))
        directory.append(contentsOf: [UInt8(SHA256.byteCount), 2, 0, 12]) // hash size, SHA-256, platform, log2(page)
        directory.append(0 as UInt32) // spare2
        directory.append(0 as UInt32) // scatter
        directory.append(0 as UInt32) // team identifier
        directory.append(0 as UInt32) // spare3
        directory.append(0 as UInt64) // 64-bit code limit
        directory.append(UInt64(text.offset))
        directory.append(UInt64(text.size))
        directory.append(0 as UInt64) // executable segment flags: not a main binary
        directory.append(identifierBytes)
        directory.append(Data(SHA256.hash(data: requirements)))
        directory.append(Data(count: SHA256.byteCount))
        for page in pages {
            directory.append(Data(SHA256.hash(data: page)))
        }

        var blob = Data()
        blob.append(0xFADE_0CC0 as UInt32)
        blob.append(UInt32(28 + directory.count + requirements.count))
        blob.append(2 as UInt32)
        blob.append(0 as UInt32) // slot: code directory
        blob.append(28 as UInt32)
        blob.append(2 as UInt32) // slot: requirements
        blob.append(UInt32(28 + directory.count))
        return blob + directory + requirements
    }

    private static func directorySize(identifier: String, codeLimit: Int) -> Int {
        directoryHeaderSize + identifier.utf8.count + 1
            + (2 + (codeLimit + pageSize - 1) / pageSize) * SHA256.byteCount
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
