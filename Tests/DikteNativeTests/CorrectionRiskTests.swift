import XCTest
@testable import DikteNative

/// A taught correction is a context-free find-and-replace. Teaching
/// "boyut" → "build" is useful when the recogniser mishears the English word,
/// but the same rule rewrites the ordinary Turkish "boyut" wherever it is really
/// meant. Nothing can tell those apart, so what the app checks instead is
/// whether the misheard side is a real word at all — the corrections that are
/// always safe replace non-words the language never produces.
@MainActor
final class CorrectionRiskTests: XCTestCase {
    func testOrdinaryTurkishWordsAreFlagged() {
        for word in ["boyut", "grafik", "mutlu", "kitap"] {
            XCTAssertTrue(CorrectionRisk.replacesARealWord(word, language: .turkish),
                          "\(word) is a real word and replacing it can misfire")
        }
    }

    func testGarbledNonWordsAreNotFlagged() {
        for word in ["syskaydı", "buyıt", "zxqwe"] {
            XCTAssertFalse(CorrectionRisk.replacesARealWord(word, language: .turkish),
                           "\(word) is not a Turkish word, so replacing it is safe")
        }
    }

    func testAMultiWordPhraseIsNotFlagged() {
        // Specific enough that an accidental match is not the concern.
        XCTAssertFalse(CorrectionRisk.replacesARealWord("bu boyut", language: .turkish))
    }

    func testEmptyInputIsNotFlagged() {
        XCTAssertFalse(CorrectionRisk.replacesARealWord("   ", language: .turkish))
    }

    func testAutomaticLanguageUsesTheTurkishDictionary() {
        XCTAssertTrue(CorrectionRisk.replacesARealWord("boyut", language: .automatic))
    }
}
