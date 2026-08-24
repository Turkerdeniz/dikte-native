import Foundation
import XCTest
@testable import DikteNative

@MainActor
final class WhisperEngineTests: XCTestCase {
    func testInstalledModelCanLoadWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DIKTE_TEST_INSTALLED_MODEL"] == "1" else {
            throw XCTSkip("Set DIKTE_TEST_INSTALLED_MODEL=1 for the local 547 MB integration test.")
        }
        XCTAssertEqual(ModelStore.expectedSHA256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.model.path))
        let engine = WhisperEngine()
        try await engine.load(modelURL: AppPaths.model)
        await engine.unload()
    }

    func testEmptySpeechChunkRequiresRetry() {
        let transcript = WhisperTranscript(text: "", meanTokenProbability: 0, tokenCount: 0)
        XCTAssertNotNil(ChunkAcceptancePolicy.issue(for: transcript, speechDuration: 8))
    }

    func testHallucinationRequiresRetry() {
        let transcript = WhisperTranscript(text: "İzlediğiniz için teşekkür ederim.",
                                           meanTokenProbability: 0.9, tokenCount: 6)
        XCTAssertNotNil(ChunkAcceptancePolicy.issue(for: transcript, speechDuration: 4))
    }

    func testRepeatedHallucinationStillRequiresRetry() {
        let transcript = WhisperTranscript(
            text: "İzlediğiniz için teşekkür ederim. Videoyu izlediğiniz için teşekkür ederim.",
            meanTokenProbability: 0.9,
            tokenCount: 19
        )
        XCTAssertNotNil(ChunkAcceptancePolicy.issue(for: transcript, speechDuration: 5))
    }

    func testImplausiblyShortChunkRequiresRetry() {
        let transcript = WhisperTranscript(text: "Tamam.", meanTokenProbability: 0.8, tokenCount: 1)
        XCTAssertNotNil(ChunkAcceptancePolicy.issue(for: transcript, speechDuration: 10))
    }

    func testHealthyTurkishChunkDoesNotRetry() {
        let transcript = WhisperTranscript(text: "Bu kayıt eksiksiz biçimde yazıya çevrildi.",
                                           meanTokenProbability: 0.82, tokenCount: 9,
                                           detectedLanguage: "tr")
        XCTAssertNil(ChunkAcceptancePolicy.issue(for: transcript, speechDuration: 5))
    }

    func testWhisperUsesMeasuredFourThreadConfiguration() {
        XCTAssertEqual(WhisperEngine.threadCount, 4)
    }
}
