@testable import AptRepository
import Foundation
import Testing

/// Lines as BigBoss serves them, the byte that is not UTF-8 spelled out.
struct IndexTextTests {
    private func line(_ head: String, _ bytes: [UInt8], _ tail: String) -> Data {
        Data(head.utf8) + Data(bytes) + Data(tail.utf8)
    }

    @Test func utf8IsReadAsWritten() {
        #expect(IndexText.decode(Data("Name: 位置伪装 (Fake GPS)\nAuthor: José\n".utf8)) == "Name: 位置伪装 (Fake GPS)\nAuthor: José\n")
    }

    @Test(arguments: [
        ("app you", [0xD5] as [UInt8], "ll find", "app you’ll find"),
        ("Author: Fran", [0x8D], "ois Pessaux", "Author: François Pessaux"),
        ("Author: Jos", [0x8E], " Daniel", "Author: José Daniel"),
        ("Cydia en Espa", [0x96], "ol", "Cydia en Español"),
        ("Author: Ali G", [0x9F], "ven", "Author: Ali Güven"),
        ("Description: Th", [0x8F], "me Officiel", "Description: Thème Officiel"),
        ("the iPhone ", [0xD0], " absolutely", "the iPhone – absolutely"),
    ])
    func macRoman(_ head: String, _ bytes: [UInt8], _ tail: String, _ expected: String) {
        #expect(IndexText.decode(line(head, bytes, tail)) == expected)
    }

    @Test(arguments: [
        ("Tema em Portugu", [0xEA] as [UInt8], "s, criado", "Tema em Português, criado"),
        ("so they don", [0x92], "t exceed", "so they don’t exceed"),
        ("the iPhone ", [0x96], " absolutely", "the iPhone – absolutely"),
    ])
    func windows1252(_ head: String, _ bytes: [UInt8], _ tail: String, _ expected: String) {
        #expect(IndexText.decode(line(head, bytes, tail)) == expected)
    }

    @Test func oneLineInAnotherEncodingLeavesTheRestUTF8() {
        let data = Data("Name: 位置伪装\n".utf8) + line("Author: Jos", [0x8E], "\n") + Data("Description: 虚拟定位\n".utf8)
        #expect(IndexText.decode(data) == "Name: 位置伪装\nAuthor: José\nDescription: 虚拟定位\n")
    }
}
