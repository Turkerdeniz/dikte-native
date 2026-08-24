import Foundation
import XCTest
@testable import DikteNative

final class ModelVerificationTests: XCTestCase {
    func testStreamingSHA256MatchesKnownDigest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: file)

        let digest = try await StreamingFileSHA256.digest(of: file)
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testReceiptMatchesOnlyUnchangedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.bin")
        try Data([1, 2, 3]).write(to: file)
        let receipt = try ModelVerificationReceipt.make(for: file, sha256: "expected")

        XCTAssertTrue(receipt.matches(file: file, expectedSize: 3, expectedSHA256: "expected"))
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertFalse(receipt.matches(file: file, expectedSize: 3, expectedSHA256: "expected"))
    }
}
