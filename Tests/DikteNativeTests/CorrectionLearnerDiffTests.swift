import XCTest
@testable import DikteNative

/// The learner used to return the single span between the common prefix and the
/// common suffix, so two separate word fixes in one sentence produced one
/// sentence-length pair. Thirty such pairs accumulated in the real store and
/// twenty-nine had never once matched, because the recogniser never repeats a
/// whole misheard sentence verbatim.
final class CorrectionLearnerDiffTests: XCTestCase {
    private func pairs(_ original: String, _ corrected: String) -> [(String, String)] {
        CorrectionLearner.candidates(original: original, corrected: corrected).map { ($0.heard, $0.corrected) }
    }

    func testTwoSeparateFixesBecomeTwoCandidatesNotOneSpan() {
        let result = pairs("bu boyut çok grafik oldu", "bu build çok graph oldu")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].0, "boyut"); XCTAssertEqual(result[0].1, "build")
        XCTAssertEqual(result[1].0, "grafik"); XCTAssertEqual(result[1].1, "graph")
    }

    func testCorrectWordsBetweenTwoFixesAreNotSwallowed() {
        // The real case from the store: everything between the first and last
        // edit used to end up inside a single unusable pair.
        let result = pairs("X kodu kapatıp sırf Package Manager'dan buyıt almam lazım",
                           "Xcode'u kapatıp Swift Package Manager'dan build almam lazım")
        for (heard, corrected) in result {
            XCTAssertFalse(heard.contains("kapatıp"), "unchanged word leaked into \(heard)")
            XCTAssertFalse(corrected.contains("kapatıp"), "unchanged word leaked into \(corrected)")
        }
        XCTAssertTrue(result.contains { $0.1 == "build" }, "expected a reusable buyıt → build pair, got \(result)")
    }

    func testASingleWordFixStillProducesOnePair() {
        XCTAssertEqual(pairs("bunu vadan aldım", "bunu VAD'dan aldım").map(\.1), ["VAD'dan"])
    }

    func testAChangedRunLongerThanTheLimitIsDropped() {
        let result = pairs("bir iki üç dört beş altı", "bir aa bb cc dd altı")
        XCTAssertTrue(result.isEmpty, "a four-word run should not be stored, got \(result)")
    }

    func testAPureInsertionIsNotOffered() {
        // Nothing to find, so there is nothing safe to replace.
        XCTAssertTrue(pairs("bunu aldım", "bunu hemen aldım").isEmpty)
    }

    func testIdenticalTextProducesNothing() {
        XCTAssertTrue(pairs("aynı cümle", "aynı cümle").isEmpty)
    }

    func testPunctuationOnlyDifferenceIsNotTaught() {
        XCTAssertTrue(pairs("merhaba dünya", "merhaba dünya.").isEmpty)
    }
}
