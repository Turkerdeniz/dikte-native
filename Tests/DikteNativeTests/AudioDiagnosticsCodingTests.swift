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

        let data = try JSONEncoder().encode(diagnostics)
        XCTAssertEqual(try JSONDecoder().decode(AudioDiagnostics.self, from: data), diagnostics)
    }

    func testAnEntryWrittenBeforeTheseFieldsExistedStillDecodes() throws {
        let legacy = #"{"callbackCount":1,"conversionErrors":0,"deviceID":"x","deviceName":"y","inputFormat":"z","peakLevel":0.1,"restartCount":0,"rmsLevel":0.01,"sampleCount":10,"transcriptionChunkCount":1,"vadSegmentCount":1,"vadSpeechDuration":1,"voicedDuration":1}"#
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.noiseFloor, 0)
        XCTAssertEqual(decoded.speechThreshold, 0)
    }
}
