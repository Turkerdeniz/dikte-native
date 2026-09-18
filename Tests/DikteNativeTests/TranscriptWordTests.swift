import XCTest
@testable import DikteNative

/// Whisper decodes sub-word tokens and reports a probability for each. Only
/// their mean used to survive, which says a recording went badly without saying
/// where. These cover the regrouping back into words and the round trip into
/// history.json — a field added to HistoryEntry and forgotten in its
/// hand-written decoder is silently destroyed on the next launch, which has
/// already happened once to the audio diagnostics.
final class TranscriptWordTests: XCTestCase {
    private func build(_ pieces: [(String, Float)]) -> [TranscriptWord] {
        var builder = TranscriptWordBuilder()
        for (piece, probability) in pieces { builder.append(piece: piece, probability: probability) }
        return builder.finish()
    }

    func testALeadingSpaceStartsANewWord() {
        let words = build([(" bu", 0.9), (" bir", 0.8), (" deneme", 0.7)])
        XCTAssertEqual(words.map(\.text), ["bu", "bir", "deneme"])
    }

    func testSubWordPiecesAreJoinedIntoOneWord() {
        let words = build([(" graph", 0.95), ("'ın", 0.30)])
        XCTAssertEqual(words.map(\.text), ["graph'ın"])
    }

    func testAWordTakesItsLeastCertainPiece() {
        // Averaging would hide the doubtful suffix behind a confident stem.
        let words = build([(" graph", 0.95), ("'ın", 0.22)])
        XCTAssertEqual(words[0].probability, 0.22, accuracy: 0.001)
        XCTAssertTrue(words[0].isUncertain)
    }

    /// The highlight and the taught-correction gate read the same probabilities
    /// for opposite reasons, so they must not drift back into one constant: the
    /// gate has to stay reachable well above where the highlight stops marking.
    /// The decoder has no left context at position 0, so a low score there is a
    /// calibration artefact rather than evidence the word is wrong. Marking it
    /// put an orange word at the head of a third of all transcripts.
    func testTheOpeningWordIsNeverMarkedHoweverLowItScores() {
        let words = [TranscriptWord(text: "Tamam,", probability: 0.05),
                     TranscriptWord(text: "bunu", probability: 0.99),
                     TranscriptWord(text: "zöktürlem", probability: 0.12)]

        XCTAssertEqual(words.uncertainIndices, [2])
        XCTAssertTrue(words[0].isUncertain, "the word itself still scores low")
    }

    func testAnEmptyOrSingleWordTranscriptMarksNothing() {
        XCTAssertTrue([TranscriptWord]().uncertainIndices.isEmpty)
        XCTAssertTrue([TranscriptWord(text: "vrımbagil.", probability: 0.12)]
            .uncertainIndices.isEmpty)
    }

    func testTheCorrectionGateReachesFurtherThanTheHighlight() {
        XCTAssertLessThan(TranscriptWord.uncertainThreshold,
                          CorrectionRisk.unsureEnoughToRewriteThreshold)

        let misheard = TranscriptWord(text: "kasaya", probability: 0.44)
        XCTAssertFalse(misheard.isUncertain, "0.44 is too ordinary to mark for the eye")
        XCTAssertEqual(TextCleaner.uncertainWordForms([misheard]), ["kasaya"],
                       "but a taught correction still has to be able to rewrite it")
    }

    func testAConfidentWordIsNotMarked() {
        XCTAssertFalse(build([(" tamam", 0.92)])[0].isUncertain)
    }

    func testTheUncertaintyBoundaryIsExclusive() {
        XCTAssertFalse(TranscriptWord(text: "x", probability: TranscriptWord.uncertainThreshold).isUncertain)
        XCTAssertTrue(TranscriptWord(text: "x", probability: TranscriptWord.uncertainThreshold - 0.01).isUncertain)
    }

    func testEmptyAndWhitespacePiecesProduceNoWords() {
        XCTAssertTrue(build([("", 0.5), ("   ", 0.5)]).isEmpty)
    }

    func testWordsSurviveTheHistoryRoundTrip() throws {
        let entry = HistoryEntry(duration: 5, mode: .dictation, rawTranscript: "graph'ın işi",
                                 finalText: "graph'ın işi", deterministicText: nil,
                                 localCorrectedText: nil,
                                 transcriptWords: [TranscriptWord(text: "graph'ın", probability: 0.3),
                                                   TranscriptWord(text: "işi", probability: 0.9)])
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
        XCTAssertEqual(decoded.first?.transcriptWords, entry.transcriptWords)
    }

    func testAnEntryWrittenBeforeThisFieldExistedStillDecodes() throws {
        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","timestamp":1,"duration":2,"mode":"dictation","rawTranscript":"a","finalText":"a"}]"#
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.first?.transcriptWords)
    }
}
