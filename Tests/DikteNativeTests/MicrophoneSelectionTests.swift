import AVFoundation
import XCTest
@testable import DikteNative

/// The capture device used to be chosen by looking for "macbook" in the
/// device's localized display name. On 9 September that selected
/// "MacBook Pro Hoparlörü" — the built-in speakers, which the microphone
/// discovery session had started listing — and every recording produced zero
/// audio packets while the capture session itself reported no error at all.
/// The name test cannot distinguish them in any language, so input capability
/// is what has to be checked.
@MainActor
final class MicrophoneSelectionTests: XCTestCase {
    func testTheBuiltInMicrophoneReportsInputChannels() throws {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                                       position: .unspecified).devices
        guard devices.contains(where: { $0.uniqueID == AudioRecorder.builtInMicrophoneUniqueID }) else {
            throw XCTSkip("No built-in microphone on this machine.")
        }
        XCTAssertTrue(AudioRecorder.deviceHasAudioInput(uniqueID: AudioRecorder.builtInMicrophoneUniqueID))
    }

    func testTheBuiltInSpeakerIsRejectedDespiteMatchingTheOldNameRule() {
        // The exact device that broke capture. It is an output device, so it has
        // no input channels even when it turns up in a microphone enumeration.
        XCTAssertFalse(AudioRecorder.deviceHasAudioInput(uniqueID: "BuiltInSpeakerDevice"))
    }

    func testTheOldNameRuleWouldHaveAcceptedTheSpeaker() {
        // Documents why the rule was replaced rather than tightened by name.
        for name in ["MacBook Pro Hoparlörü", "MacBook Pro Speakers"] {
            let folded = name.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
            XCTAssertTrue(folded.contains("macbook") && !folded.contains("iphone"),
                          "\(name) passed the old rule, which is the defect")
        }
    }
}
