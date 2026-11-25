import Foundation
import Testing
@testable import DownloadKit

@Test func hashesBytesAndFilesTheSame() throws {
    #expect(SHA256Hex.of(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(SHA256Hex.of(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let body = Samples.bytes(3_500_000)    // more than three chunks
    let file = Samples.folder().appending(path: "big.bin")
    try body.write(to: file)
    var reads: [Int64] = []
    #expect(try SHA256Hex.ofFile(file) { reads.append($0) } == SHA256Hex.of(body))
    #expect(reads.last == 3_500_000 && reads.count == 4)
}

@Test func aMissingFileThrows() {
    #expect(throws: (any Error).self) { try SHA256Hex.ofFile(Samples.folder().appending(path: "none")) }
}

@Test func normalizesHashes() {
    let hash = String(repeating: "ab", count: 32)
    #expect(SHA256Hex.normalized(" " + hash.uppercased() + "\n") == hash)
    #expect(SHA256Hex.normalized("sha256:" + hash) == hash)
    #expect(SHA256Hex.normalized(String(hash.dropLast())) == nil)
    #expect(SHA256Hex.normalized(String(repeating: "g", count: 64)) == nil)
    #expect(SHA256Hex.matches(hash.uppercased(), "sha256:" + hash))
    #expect(!SHA256Hex.matches("nope", "nope"))
}

@Test func findsAFileInEveryChecksumsLayout() {
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)
    // sha256sum, text and binary mode.
    let gnu = "\(a)  supermetroid-0.4.6-macos-arm64.zip\n\(b) *SHA256SUMS-other.zip\n"
    #expect(SHA256Hex.find(for: "supermetroid-0.4.6-macos-arm64.zip", in: gnu) == a)
    #expect(SHA256Hex.find(for: "SHA256SUMS-other.zip", in: gnu) == b)
    #expect(SHA256Hex.find(for: "missing.zip", in: gnu) == nil)
    // renpy.org's checksums.txt mixes MD5, SHA-1 and SHA-256 lines.
    let mixed = """
    d41d8cd98f00b204e9800998ecf8427e renpy-8.3.4-sdk.tar.bz2
    da39a3ee5e6b4b0d3255bfef95601890afd80709 renpy-8.3.4-sdk.tar.bz2
    \(c.uppercased()) renpy-8.3.4-sdk.tar.bz2
    """
    #expect(SHA256Hex.find(for: "renpy-8.3.4-sdk.tar.bz2", in: mixed) == c)
    // BSD, a folder in front, Windows line ends, a name with spaces.
    #expect(SHA256Hex.find(for: "app.dmg", in: "SHA256 (app.dmg) = \(b)") == b)
    #expect(SHA256Hex.find(for: "app.dmg", in: "\(a)  dist/app.dmg\r\n") == a)
    #expect(SHA256Hex.find(for: "My Game.zip", in: "\(a)  My Game.zip") == a)
    // A lone hash in "<name>.sha256".
    #expect(SHA256Hex.find(for: "bg3se.zip", in: "\(b)\n") == b)
    #expect(SHA256Hex.find(for: "bg3se.zip", in: "\(b)\n\(c)\n") == nil)
}
