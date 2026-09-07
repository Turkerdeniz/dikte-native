import XCTest
@testable import DikteNative

/// Covers the confidence gate that decides whether an assembled transcript is
/// trustworthy enough to be delivered as a normal result. The gate must fire on
/// the hallucination signature (low mean probability *and* mostly weak tokens)
/// and stay silent everywhere else, because a false positive downgrades speech
/// the user actually produced.
final class TranscriptionConfidenceTests: XCTestCase {
    func testFlagsATranscriptThatIsBothLowMeanAndMostlyWeakTokens() {
        XCTAssertTrue(TranscriptionPolicy.isConfidenceTooLow(meanTokenProbability: 0.22,
                                                             lowConfidenceTokenRatio: 0.85,
                                                             tokenCount: 20))
    }

    func testAcceptsAConfidentTranscript() {
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(meanTokenProbability: 0.88,
                                                              lowConfidenceTokenRatio: 0.05,
                                                              tokenCount: 20))
    }

    func testALowMeanAloneIsNotEnough() {
        // Difficult audio can depress the mean while still leaving confident
        // anchors; that is recoverable speech, not an invention.
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(meanTokenProbability: 0.30,
                                                              lowConfidenceTokenRatio: 0.40,
                                                              tokenCount: 20))
    }

    func testManyWeakTokensAloneIsNotEnough() {
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(meanTokenProbability: 0.55,
                                                              lowConfidenceTokenRatio: 0.90,
                                                              tokenCount: 20))
    }

    func testVeryShortOutputIsExemptBecauseTheMeanIsTooNoisyToJudge() {
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(meanTokenProbability: 0.10,
                                                              lowConfidenceTokenRatio: 1.0,
                                                              tokenCount: 3))
    }

    func testTheShortOutputExemptionEndsAtTheDocumentedTokenCount() {
        XCTAssertTrue(TranscriptionPolicy.isConfidenceTooLow(
            meanTokenProbability: 0.10, lowConfidenceTokenRatio: 1.0,
            tokenCount: TranscriptionPolicy.minimumTokensForConfidenceJudgement))
    }

    func testThresholdsAreExclusiveSoAValueExactlyOnTheBoundaryPasses() {
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(
            meanTokenProbability: TranscriptionPolicy.hallucinationMeanProbability,
            lowConfidenceTokenRatio: 1.0, tokenCount: 20))
        XCTAssertFalse(TranscriptionPolicy.isConfidenceTooLow(
            meanTokenProbability: 0.0,
            lowConfidenceTokenRatio: TranscriptionPolicy.hallucinationWeakTokenRatio,
            tokenCount: 20))
    }
}
