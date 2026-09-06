import XCTest
@testable import DikteNative

@MainActor
final class SettingsMigrationTests: XCTestCase {
    func testLegacyPointOneThresholdMigratesToThirtySeconds() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.1, forKey: "codexThreshold")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.codexThreshold, 30)
    }

    func testDisabledCodexThresholdRemainsDisabled() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.0, forKey: "codexThreshold")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.codexThreshold, 0)
    }

    func testRemovedQwenSettingIsDeletedDuringMigration() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "migrationVersion")
        defaults.set(true, forKey: "smartCleanupEnabled")

        _ = AppSettings(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "smartCleanupEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "migrationVersion"), 8)
    }

    func testOverlayMigratesToCompactBottomLeft() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "migrationVersion")
        defaults.set("top", forKey: "overlayPosition")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.overlayPosition, .bottomLeft)
        XCTAssertEqual(defaults.string(forKey: "overlayPosition"), OverlayPosition.bottomLeft.rawValue)
    }

    func testLanguageMigratesToTurkish() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: "migrationVersion")
        defaults.set("automatic", forKey: "language")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.language, .turkish)
        XCTAssertEqual(defaults.string(forKey: "language"), RecognitionLanguage.turkish.rawValue)
    }

    func testEditingContractMigrationResetsLegacyCodexThreadOnce() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "migrationVersion")
        defaults.set("legacy-thread", forKey: "codexThreadID")

        let migrated = AppSettings(defaults: defaults)

        XCTAssertNil(migrated.codexThreadID)
        XCTAssertNil(defaults.string(forKey: "codexThreadID"))
        XCTAssertEqual(defaults.integer(forKey: "migrationVersion"), 8)

        defaults.set("new-editor-thread", forKey: "codexThreadID")
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.codexThreadID, "new-editor-thread")
    }

    func testCodingThreadMigratesSeparatelyFromGeneralThread() {
        let suite = "DikteNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(6, forKey: "migrationVersion")
        defaults.set("general-thread", forKey: "codexThreadID")
        defaults.set("pre-feature-thread", forKey: "codingCodexThreadID")

        let migrated = AppSettings(defaults: defaults)

        XCTAssertEqual(migrated.codexThreadID, "general-thread")
        XCTAssertNil(migrated.codingCodexThreadID)
        XCTAssertNil(defaults.string(forKey: "codingCodexThreadID"))
        XCTAssertEqual(defaults.integer(forKey: "migrationVersion"), 8)

        defaults.set("coding-thread", forKey: "codingCodexThreadID")
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.codexThreadID, "general-thread")
        XCTAssertEqual(relaunched.codingCodexThreadID, "coding-thread")
    }
}
