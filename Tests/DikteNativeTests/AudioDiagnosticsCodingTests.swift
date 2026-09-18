import XCTest
@testable import DikteNative

/// The noise floor and the derived speech threshold are the only evidence we
/// have about what a room actually sounded like during a capture, so they have
/// to survive the round trip into history.json. They silently did not once
/// before, which invalidated a measurement.
final class AudioDiagnosticsCodingTests: XCTestCase {
    func testNoiseFloorAndThresholdSurviveEncodingAndDecoding() throws {
        var diagnostics = AudioDiagnostics(deviceName: "MacBook Pro Mikrofonu")
        diagnostics.noiseFloor = 0.00281
        diagnostics.speechThreshold = 0.00844

        let data = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: data)

        XCTAssertEqual(decoded.noiseFloor, 0.00281, accuracy: 0.000_001)
        XCTAssertEqual(decoded.speechThreshold, 0.00844, accuracy: 0.000_001)
    }

    func testTheEncodedFormActuallyCarriesTheKeys() throws {
        var diagnostics = AudioDiagnostics()
        diagnostics.noiseFloor = 0.5
        diagnostics.speechThreshold = 0.25
        let json = String(data: try JSONEncoder().encode(diagnostics), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("noiseFloor"), "noiseFloor missing from \(json)")
        XCTAssertTrue(json.contains("speechThreshold"), "speechThreshold missing from \(json)")
    }

    /// Field-agnostic on purpose: every stored property is given a value that
    /// differs from its default, so `Equatable` catches any field a future edit
    /// adds to the struct but forgets in the hand-written initialiser. The
    /// per-field assertions above stay because they name what was actually lost.
    func testEveryFieldSurvivesTheRoundTrip() throws {
        var diagnostics = AudioDiagnostics()
        diagnostics.deviceID = "id"
        diagnostics.deviceName = "name"
        diagnostics.inputFormat = "format"
        diagnostics.callbackCount = 1
        diagnostics.sampleCount = 2
        diagnostics.peakLevel = 0.3
        diagnostics.rmsLevel = 0.4
        diagnostics.voicedDuration = 5
        diagnostics.restartCount = 6
        diagnostics.conversionErrors = 7
        diagnostics.vadSegmentCount = 8
        diagnostics.transcriptionChunkCount = 9
        diagnostics.vadSpeechDuration = 10
        diagnostics.vadFallbackReason = "vad"
        diagnostics.noiseFloor = 0.11
        diagnostics.speechThreshold = 0.12
        diagnostics.armingMilliseconds = 13
        diagnostics.sessionStartMilliseconds = 14
        diagnostics.processAgeSeconds = 15
        diagnostics.modelWasResident = true

        let data = try JSONEncoder().encode(diagnostics)
        XCTAssertEqual(try JSONDecoder().decode(AudioDiagnostics.self, from: data), diagnostics)
    }

    /// The arming window is the reason the overlay's entrance is delayed at all,
    /// so it has to reach history.json rather than being computed and dropped.
    func testTheArmingWindowSurvivesAndIsReported() throws {
        var diagnostics = AudioDiagnostics(deviceName: "MacBook Pro Mikrofonu")
        diagnostics.armingMilliseconds = 413.2
        diagnostics.sessionStartMilliseconds = 190.4

        let data = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: data)

        XCTAssertEqual(decoded.armingMilliseconds, 413.2, accuracy: 0.001)
        XCTAssertEqual(decoded.sessionStartMilliseconds, 190.4, accuracy: 0.001)
        XCTAssertTrue(decoded.summary.contains("hazırlanma 413 ms"), decoded.summary)
        XCTAssertTrue(decoded.summary.contains("oturum 190 ms"), decoded.summary)
    }

    /// An unmeasured recording must not report a confident zero.
    func testAnUnmeasuredArmingWindowIsNotReported() {
        XCTAssertFalse(AudioDiagnostics(deviceName: "x").summary.contains("hazırlanma"))
    }

    /// The arming figures are only interpretable next to the state the capture
    /// started in. Grouping them by the process's memory footprint instead was
    /// a proxy that comes apart the moment the idle-release timer fires.
    func testTheCaptureContextIsRecordedAndReported() throws {
        var diagnostics = AudioDiagnostics(deviceName: "x")
        diagnostics.armingMilliseconds = 116
        diagnostics.processAgeSeconds = 8.4
        diagnostics.modelWasResident = false

        let decoded = try JSONDecoder().decode(
            AudioDiagnostics.self, from: try JSONEncoder().encode(diagnostics))

        XCTAssertEqual(decoded.processAgeSeconds, 8.4, accuracy: 0.001)
        XCTAssertEqual(decoded.modelWasResident, false)
        XCTAssertTrue(decoded.summary.contains("süreç yaşı 8 sn"), decoded.summary)
        XCTAssertTrue(decoded.summary.contains("model bellekte değil"), decoded.summary)
    }

    /// Absent is not false. A recording made before this field existed did not
    /// measure residency, and reporting it as "not resident" would be a claim.
    func testResidencyIsAbsentRatherThanFalseWhenItWasNeverMeasured() throws {
        let legacy = #"{"deviceName":"x","armingMilliseconds":90}"#
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.modelWasResident)
        XCTAssertEqual(decoded.processAgeSeconds, 0)
        XCTAssertFalse(decoded.summary.contains("model bellekte"), decoded.summary)
        XCTAssertFalse(decoded.summary.contains("süreç yaşı"), decoded.summary)
    }

    /// Read from the kernel, so it is the real process start rather than
    /// whenever something first happened to ask.
    func testProcessAgeIsPositiveAndPlausible() {
        let age = ProcessClock.ageSeconds
        XCTAssertGreaterThan(age, 0)
        XCTAssertLessThan(age, 60 * 60 * 24)
    }

    func testAnEntryWrittenBeforeTheseFieldsExistedStillDecodes() throws {
        let legacy = #"{"callbackCount":1,"conversionErrors":0,"deviceID":"x","deviceName":"y","inputFormat":"z","peakLevel":0.1,"restartCount":0,"rmsLevel":0.01,"sampleCount":10,"transcriptionChunkCount":1,"vadSegmentCount":1,"vadSpeechDuration":1,"voicedDuration":1}"#
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.noiseFloor, 0)
        XCTAssertEqual(decoded.speechThreshold, 0)
    }
}
