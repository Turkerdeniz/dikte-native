import XCTest
@testable import DikteNative

/// A taught correction is a find-and-replace, so "boyut" → "build" also rewrote
/// the ordinary Turkish word wherever it was genuinely meant. The recogniser's
/// own certainty separates the two cases: a word the user really said comes back
/// confident, a word it misheard comes back doubtful.
@MainActor
final class ContextualCorrectionTests: XCTestCase {
    private let risky = CorrectionEntry(heard: "boyut", corrected: "build")
    private let safe = CorrectionEntry(heard: "buyıt", corrected: "build")

    private func confident(_ text: String) -> [TranscriptWord] {
        text.split(separator: " ").map { TranscriptWord(text: String($0), probability: 0.95) }
    }
    private func doubting(_ text: String, _ word: String) -> [TranscriptWord] {
        text.split(separator: " ").map {
            TranscriptWord(text: String($0), probability: String($0) == word ? 0.30 : 0.95)
        }
    }

    func testARealWordIsLeftAloneWhenTheRecogniserWasSureOfIt() {
        let (text, applied) = TextCleaner.applyCorrections(
            "ekranın boyut ayarı", entries: [risky],
            words: confident("ekranın boyut ayarı"), language: .turkish)
        XCTAssertEqual(text, "ekranın boyut ayarı")
        XCTAssertTrue(applied.isEmpty)
    }

    func testTheSameWordIsCorrectedWhenTheRecogniserWasUnsure() {
        let (text, applied) = TextCleaner.applyCorrections(
            "bu boyut aldım", entries: [risky],
            words: doubting("bu boyut aldım", "boyut"), language: .turkish)
        XCTAssertEqual(text, "bu build aldım")
        XCTAssertEqual(applied, [risky.id])
    }

    func testANonWordIsCorrectedRegardlessOfCertainty() {
        // "buyıt" has no second sense to damage, so it stays unconditional.
        let (text, applied) = TextCleaner.applyCorrections(
            "bu buyıt aldım", entries: [safe],
            words: confident("bu buyıt aldım"), language: .turkish)
        XCTAssertEqual(text, "bu build aldım")
        XCTAssertEqual(applied, [safe.id])
    }

    func testWithoutWordCertaintyTheOldBehaviourIsKept() {
        // A path with no per-word data must not become worse than it was.
        let (text, applied) = TextCleaner.applyCorrections("ekranın boyut ayarı", entries: [risky])
        XCTAssertEqual(text, "ekranın build ayarı")
        XCTAssertEqual(applied, [risky.id])
    }

    func testCertaintyIsMatchedIgnoringCaseAndPunctuation() {
        let words = [TranscriptWord(text: "Boyut,", probability: 0.30)]
        let (text, _) = TextCleaner.applyCorrections("boyut", entries: [risky],
                                                     words: words, language: .turkish)
        XCTAssertEqual(text, "build")
    }

    func testADisabledCorrectionNeverFires() {
        let off = CorrectionEntry(heard: "boyut", corrected: "build", isEnabled: false)
        let (text, applied) = TextCleaner.applyCorrections(
            "bu boyut aldım", entries: [off],
            words: doubting("bu boyut aldım", "boyut"), language: .turkish)
        XCTAssertEqual(text, "bu boyut aldım")
        XCTAssertTrue(applied.isEmpty)
    }
}
