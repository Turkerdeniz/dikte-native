import XCTest
@testable import DikteNative

final class TextCleanerTests: XCTestCase {
    func testMojibakeAndSpacing() {
        XCTAssertEqual(TextCleaner.clean("konu≈üan  b√∂yle ,hƒ±zlƒ±ca"), "konuşan böyle, hızlıca")
    }

    func testImmediateRepetitionOnly() {
        XCTAssertEqual(TextCleaner.clean("bu bu bir test test"), "bu bir test")
        XCTAssertEqual(TextCleaner.clean("çok iyi ve çok hızlı"), "çok iyi ve çok hızlı")
    }

    func testThresholdIsStrictlyGreater() {
        XCTAssertFalse(RoutePolicy.shouldUseCodex(duration: 30.0, threshold: 30.0))
        XCTAssertTrue(RoutePolicy.shouldUseCodex(duration: 30.1, threshold: 30.0))
        XCTAssertFalse(RoutePolicy.shouldUseCodex(duration: 90, threshold: 0))
    }

    func testSilenceHallucinationPolicy() {
        XCTAssertFalse(TranscriptionPolicy.accepts("İzlediğiniz için teşekkür ederim.", voicedDuration: 0.4))
        XCTAssertFalse(TranscriptionPolicy.accepts(
            "İzlediğiniz için teşekkür ederim. Videoyu izlediğiniz için teşekkür ederim.",
            voicedDuration: 4.7
        ))
        XCTAssertFalse(TranscriptionPolicy.accepts(
            "Lütfen kanalıma abone olmayı ve videoyu beğenmeyi unutmayın.",
            voicedDuration: 1.8
        ))
        XCTAssertTrue(TranscriptionPolicy.accepts("Bugün üniversite başlayacak.", voicedDuration: 1.2))
        XCTAssertTrue(TranscriptionPolicy.accepts(
            "Düzgün duymayınca izlediğiniz için teşekkür ederim gibi saçma şeyler yazıyor.",
            voicedDuration: 6
        ))
    }

    func testCorrectionLearnerRequiresAnExplicitChangedSpan() {
        let candidates = CorrectionLearner.candidates(
            original: "Bu bir deneme syskaydı ve Kodeks'e gidecek.",
            corrected: "Bu bir deneme ses kaydı ve Codex'e gidecek."
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].heard.contains("syskaydı"))
        XCTAssertTrue(candidates[0].corrected.contains("ses"))
    }

    func testApplyCorrectionsReplacesAConfirmedMatchAndReportsWhichFired() {
        let entry = CorrectionEntry(heard: "Kodeks", corrected: "Codex")
        let (text, appliedIDs) = TextCleaner.applyCorrections("Kodeks'e gönderiyorum.", entries: [entry])
        XCTAssertEqual(text, "Codex'e gönderiyorum.")
        XCTAssertEqual(appliedIDs, [entry.id])
    }

    func testApplyCorrectionsIsCaseInsensitive() {
        let entry = CorrectionEntry(heard: "kodeks", corrected: "Codex")
        let (text, appliedIDs) = TextCleaner.applyCorrections("KODEKS çalışıyor.", entries: [entry])
        XCTAssertEqual(text, "Codex çalışıyor.")
        XCTAssertEqual(appliedIDs, [entry.id])
    }

    func testApplyCorrectionsDoesNotFireOnAPartialWordMatch() {
        let entry = CorrectionEntry(heard: "kod", corrected: "code")
        let (text, appliedIDs) = TextCleaner.applyCorrections("Kodeks çalışmıyor.", entries: [entry])
        XCTAssertEqual(text, "Kodeks çalışmıyor.")
        XCTAssertTrue(appliedIDs.isEmpty)
    }

    func testApplyCorrectionsSkipsDisabledEntries() {
        let entry = CorrectionEntry(heard: "Kodeks", corrected: "Codex", isEnabled: false)
        let (text, appliedIDs) = TextCleaner.applyCorrections("Kodeks'e gönderiyorum.", entries: [entry])
        XCTAssertEqual(text, "Kodeks'e gönderiyorum.")
        XCTAssertTrue(appliedIDs.isEmpty)
    }

    func testApplyCorrectionsReportsNoMatchWhenTheHeardTermIsAbsent() {
        let entry = CorrectionEntry(heard: "Kodeks", corrected: "Codex")
        let (text, appliedIDs) = TextCleaner.applyCorrections("Bugün hava güzel.", entries: [entry])
        XCTAssertEqual(text, "Bugün hava güzel.")
        XCTAssertTrue(appliedIDs.isEmpty)
    }
}
