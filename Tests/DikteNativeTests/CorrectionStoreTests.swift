import XCTest
@testable import DikteNative

@MainActor
final class CorrectionStoreTests: XCTestCase {
    private func makeStore() -> CorrectionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DikteNativeTests-corrections-\(UUID().uuidString).json")
        return CorrectionStore(fileURL: url)
    }

    func testConfirmDoesNotCountAsUse() {
        // Re-teaching an already-known pair re-enables it but is not, itself,
        // evidence the correction ever fired in a real transcript.
        let store = makeStore()
        let candidate = CorrectionCandidate(heard: "Kodeks", corrected: "Codex")
        store.confirm([candidate])
        store.setEnabled(id: store.entries[0].id, enabled: false)
        store.confirm([candidate])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.entries[0].isEnabled)
        XCTAssertEqual(store.entries[0].useCount, 0)
    }

    func testRecordAppliedIncrementsOnlyTheMatchingEntry() {
        let store = makeStore()
        store.confirm([
            CorrectionCandidate(heard: "Kodeks", corrected: "Codex"),
            CorrectionCandidate(heard: "syskaydı", corrected: "ses kaydı")
        ])
        let codexID = store.entries.first { $0.heard == "Kodeks" }!.id
        store.recordApplied([codexID])
        store.recordApplied([codexID])
        XCTAssertEqual(store.entries.first { $0.heard == "Kodeks" }?.useCount, 2)
        XCTAssertEqual(store.entries.first { $0.heard == "syskaydı" }?.useCount, 0)
    }

    func testEndToEndConfirmedCorrectionAppliesOnTheNextTranscript() {
        // The full loop this fix closes: teach once, then a later transcript is
        // deterministically corrected without depending on Whisper's soft
        // vocabulary hint guessing right.
        let store = makeStore()
        store.confirm([CorrectionCandidate(heard: "Kodeks", corrected: "Codex")])
        let cleaned = TextCleaner.clean("Bunu Kodeks'e gönderiyorum.")
        let (corrected, appliedIDs) = TextCleaner.applyCorrections(cleaned, entries: store.entries)
        store.recordApplied(appliedIDs)
        XCTAssertEqual(corrected, "Bunu Codex'e gönderiyorum.")
        XCTAssertEqual(store.entries[0].useCount, 1)
    }
}
