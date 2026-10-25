import Foundation
import Testing

@testable import WorkbenchCore

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Ours, named so it cannot be mistaken for CryptoKit's when both are in scope.
private typealias Ours = WorkbenchCore.SHA256

private func hex(_ digest: [UInt8]) -> String { digest.map { String(format: "%02x", $0) }.joined() }

/// The hash behind every fingerprint Workbench writes. Held to the published vectors on every OS, and on macOS to CryptoKit.
@Suite struct SHA256Tests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        (
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        ),
        ("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
    ])
    func thePublishedVectors(message: String, expected: String) {
        #expect(hex(Ours.hash(data: Data(message.utf8))) == expected)
    }

    @Test func aMillionAsGivesTheFipsDigest() {
        var hasher = Ours()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 1_000)
        for _ in 0..<1_000 { hasher.update(data: chunk) }
        #expect(hex(hasher.finalize()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func feedingInPiecesGivesTheSameDigestAtEverySplitAroundTheBlockBoundaries() {
        for length in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 200] {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
            let whole = Ours.hash(data: data)
            for split in 0...length {
                var hasher = Ours()
                hasher.update(data: data.prefix(split))
                hasher.update(data: data.dropFirst(split))
                #expect(hasher.finalize() == whole, "length \(length), split at \(split)")
            }
        }
    }

    @Test func finalizingDoesNotSpoilTheHasherSoMoreInputMayFollow() {
        var hasher = Ours()
        hasher.update(data: Data("ab".utf8))
        _ = hasher.finalize()
        hasher.update(data: Data("c".utf8))
        #expect(hex(hasher.finalize()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func aSliceOfDataThatDoesNotStartAtZeroIsHashedByItsContent() {
        let backing = Data("xxabcxx".utf8)
        let slice = backing[2..<5]
        #expect(slice.startIndex == 2)
        #expect(hex(Ours.hash(data: slice)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    #if canImport(CryptoKit)
    @Test func itAgreesWithCryptoKitOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        for length in Array(0...300) + [1_000, 4_096, 65_535, 1 << 20] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(Ours.hash(data: data) == Array(CryptoKit.SHA256.hash(data: data)), "length \(length)")
        }
    }
    #endif
}
