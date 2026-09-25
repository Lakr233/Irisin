import Foundation
import TreeSitter

protocol TreeSitterParserDelegate: AnyObject {
    func parser(_ parser: TreeSitterParser, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult?
}

final class TreeSitterParser {
    weak var delegate: TreeSitterParserDelegate?
    let encoding: TSInputEncoding
    var language: UnsafePointer<TSLanguage>? {
        didSet {
            ts_parser_set_language(pointer, language)
        }
    }

    var canParse: Bool {
        language != nil
    }

    private var pointer: UnsafeMutablePointer<TSParser>

    init(encoding: TSInputEncoding) {
        self.encoding = encoding
        pointer = ts_parser_new()!
    }

    deinit {
        ts_parser_delete(pointer)
    }

    func parse(_ string: NSString, oldTree: TreeSitterTree? = nil) -> TreeSitterTree? {
        guard string.length > 0 else {
            return nil
        }
        guard let stringEncoding = encoding.stringEncoding else {
            return nil
        }
        var usedLength = 0
        let buffer = string.getAllBytes(withEncoding: stringEncoding, usedLength: &usedLength)
        let newTreePointer = ts_parser_parse_string_encoding(pointer, oldTree?.pointer, buffer, UInt32(usedLength), encoding)
        buffer?.deallocate()
        if let newTreePointer {
            return TreeSitterTree(newTreePointer)
        } else {
            return nil
        }
    }

    func parse(oldTree: TreeSitterTree? = nil) -> TreeSitterTree? {
        let input = TreeSitterTextInput(encoding: encoding) { [weak self] byteIndex, _ in
            if let self {
                return delegate?.parser(self, bytesAt: byteIndex)
            } else {
                return nil
            }
        }
        let newTreePointer = ts_parser_parse(pointer, oldTree?.pointer, input.makeTSInput())
        input.deallocate()
        if let newTreePointer {
            return TreeSitterTree(newTreePointer)
        } else {
            return nil
        }
    }

    @discardableResult
    func setIncludedRanges(_ ranges: [TreeSitterTextRange]) -> Bool {
        let rawRanges = ranges.map(\.rawValue)
        return rawRanges.withUnsafeBufferPointer { rangesPointer in
            ts_parser_set_included_ranges(pointer, rangesPointer.baseAddress, UInt32(rawRanges.count))
        }
    }

    func removeAllIncludedRanges() {
        ts_parser_set_included_ranges(pointer, nil, 0)
    }
}

private extension TSInputEncoding {
    var stringEncoding: String.Encoding? {
        switch self {
        case TSInputEncodingUTF8:
            .utf8
        case TSInputEncodingUTF16:
            String.preferredUTF16Encoding
        default:
            nil
        }
    }
}
