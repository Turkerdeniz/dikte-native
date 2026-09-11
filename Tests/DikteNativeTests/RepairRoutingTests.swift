import XCTest
@testable import DikteNative

/// Duration alone decided whether a transcript got repaired, so in practice more
/// than half of the recordings — median under seven seconds — never did,
/// however badly they came out. Confidence is the direct evidence, and it was
/// already being computed and thrown away for this purpose.
final class RepairRoutingTests: XCTestCase {
    private let threshold: TimeInterval = 20

    func testAConfidentShortRecordingStaysLocal() {
        XCTAssertEqual(
            RoutePolicy.destination(for: .general, duration: 7, threshold: threshold,
                                    confidence: 0.88, tokenCount: 30),
            .local)
    }

    func testAGarbledShortRecordingIsSentForRepair() {
        XCTAssertEqual(
            RoutePolicy.destination(for: .general, duration: 7, threshold: threshold,
                                    confidence: 0.61, tokenCount: 30),
            .codex)
    }

    func testAVeryShortUtteranceIsLeftAloneEvenWhenConfidenceLooksPoor() {
        // "Teşekkürler." scores 0.666 simply because there is almost nothing to
        // average. Routing it would buy the user a wait and no correction.
        XCTAssertEqual(
            RoutePolicy.destination(for: .general, duration: 2.6, threshold: threshold,
                                    confidence: 0.666, tokenCount: 3),
            .local)
    }

    func testDurationStillRoutesOnItsOwnRegardlessOfConfidence() {
        XCTAssertEqual(
            RoutePolicy.destination(for: .general, duration: 25, threshold: threshold,
                                    confidence: 0.95, tokenCount: 200),
            .codex)
    }

    func testAMissingConfidenceNeverRoutesByItself() {
        XCTAssertEqual(
            RoutePolicy.destination(for: .general, duration: 7, threshold: threshold,
                                    confidence: nil, tokenCount: 30),
            .local)
    }

    func testCodingModeIsUnaffected() {
        XCTAssertEqual(
            RoutePolicy.destination(for: .coding, duration: 1, threshold: threshold,
                                    confidence: 0.99, tokenCount: 100),
            .codex)
    }

    func testTheConfidenceBoundaryIsExclusive() {
        XCTAssertFalse(RoutePolicy.needsRepair(confidence: RoutePolicy.repairConfidenceThreshold,
                                               tokenCount: 50))
        XCTAssertTrue(RoutePolicy.needsRepair(confidence: RoutePolicy.repairConfidenceThreshold - 0.01,
                                              tokenCount: 50))
    }

    func testTheTokenMinimumIsInclusive() {
        XCTAssertTrue(RoutePolicy.needsRepair(confidence: 0.5,
                                              tokenCount: RoutePolicy.minimumTokensForRepair))
        XCTAssertFalse(RoutePolicy.needsRepair(confidence: 0.5,
                                               tokenCount: RoutePolicy.minimumTokensForRepair - 1))
    }
}
