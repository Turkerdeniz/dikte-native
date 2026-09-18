@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

/// The waveform is presentation-only; this maps a linear RMS value to a
/// perceptually smoother display level. Shared by every capture driver.
private func displayLevel(forRMS rms: Float) -> Float { min(1, pow(max(0, rms), 0.45) * 1.8) }

private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var diagnostics = AudioDiagnostics()
    private var squaredSum: Double = 0
    private var voicedSamples = 0

    func reset(device: AVCaptureDevice, restartCount: Int) {
        lock.withLock {
            storage.removeAll(keepingCapacity: false)
            diagnostics = AudioDiagnostics(deviceID: device.uniqueID, deviceName: device.localizedName,
                                           restartCount: restartCount)
            squaredSum = 0
            voicedSamples = 0
        }
    }

    func append(_ values: UnsafeBufferPointer<Float>, inputFormat: String) -> Float {
        lock.withLock {
            guard !values.isEmpty else { return 0 }
            var peak: Float = 0
            var packetSquared: Double = 0
            var packetVoiced = 0
            for value in values {
                let magnitude = abs(value)
                peak = max(peak, magnitude)
                let square = Double(value * value)
                packetSquared += square
                if magnitude >= 0.008 { packetVoiced += 1 }
            }
            storage.append(contentsOf: values)
            squaredSum += packetSquared
            voicedSamples += packetVoiced
            diagnostics.inputFormat = inputFormat
            diagnostics.callbackCount += 1
            diagnostics.sampleCount = storage.count
            diagnostics.peakLevel = max(diagnostics.peakLevel, peak)
            diagnostics.rmsLevel = Float(sqrt(squaredSum / Double(max(1, storage.count))))
            diagnostics.voicedDuration = Double(voicedSamples) / 16_000.0
            return Float(sqrt(packetSquared / Double(values.count)))
        }
    }

    func noteConversionError(_ description: String) {
        lock.withLock {
            diagnostics.conversionErrors += 1
            if diagnostics.inputFormat.isEmpty { diagnostics.inputFormat = description }
        }
    }

    func snapshot(duration: TimeInterval) -> AudioCapture {
        lock.withLock {
            var current = diagnostics
            current.sampleCount = storage.count
            return AudioCapture(samples: storage, sampleRate: 16_000, duration: duration,
                                diagnostics: current)
        }
    }

    func take(duration: TimeInterval) -> AudioCapture {
        lock.withLock {
            var current = diagnostics
            current.sampleCount = storage.count
            let capture = AudioCapture(samples: storage, sampleRate: 16_000, duration: duration,
                                       diagnostics: current)
            // Do not retain the capacity of a five-minute recording for the rest of the
            // process lifetime. The next recording grows naturally from an empty buffer.
            storage.removeAll(keepingCapacity: false)
            diagnostics = AudioDiagnostics()
            squaredSum = 0
            voicedSamples = 0
            return capture
        }
    }
}

/// A single-shot flag for `AVAudioConverter`'s input block: the source buffer
/// is handed over once, then the block reports no more data. `@unchecked
/// Sendable` because the converter invokes it synchronously on the calling
/// thread, never concurrently.
private final class ConverterInputState: @unchecked Sendable { var supplied = false }

private final class CaptureOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.turkerdenizer.dikte.audio-samples", qos: .userInteractive)
    private let accumulator: SampleAccumulator
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private var cachedSourceFormat: AVAudioFormat?
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceBuffer: AVAudioPCMBuffer?
    private var cachedOutputBuffer: AVAudioPCMBuffer?
    private var deliveredFirstSample = false
    var onFirstSample: (@MainActor @Sendable () -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?

    init(accumulator: SampleAccumulator) { self.accumulator = accumulator }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            let converted = try convert(sampleBuffer)
            guard let channel = converted.floatChannelData?[0] else {
                accumulator.noteConversionError("16 kHz Float32 kanal verisi alınamadı")
                return
            }
            let values = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
            let source = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap(AVAudioFormat.init(cmAudioFormatDescription:))
            let description = source.map(Self.describe) ?? "Bilinmeyen CoreAudio formatı"
            let rms = accumulator.append(values, inputFormat: description)
            if !deliveredFirstSample {
                deliveredFirstSample = true
                if let onFirstSample { Task { @MainActor in onFirstSample() } }
            }
            // Every buffer is handed over as it arrives; the meter downstream owns the
            // display cadence. Dropping buffers here with a wall-clock "not yet" gate
            // rounded the update rate up to the next whole hardware buffer period, and
            // because that rounding drifted against the meter's own timer the bar strip
            // advanced every 17-67 ms instead of every 33 ms, with two- and three-bar
            // catch-up leaps that read as a flicker.
            onLevel?(displayLevel(forRMS: rms))
        } catch {
            accumulator.noteConversionError(error.localizedDescription)
        }
    }

    private func convert(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DikteError.message("Mikrofon ses formatı okunamadı.")
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else {
            throw DikteError.message("Mikrofon tamponu oluşturulamadı.")
        }
        let sourceBuffer: AVAudioPCMBuffer
        if let cachedSourceBuffer, cachedSourceBuffer.format == sourceFormat,
           cachedSourceBuffer.frameCapacity >= frameCount {
            sourceBuffer = cachedSourceBuffer
        } else if let newBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) {
            cachedSourceBuffer = newBuffer
            sourceBuffer = newBuffer
        } else {
            throw DikteError.message("Mikrofon tamponu oluşturulamadı.")
        }
        sourceBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw DikteError.message("Mikrofon tamponu okunamadı (\(copyStatus)).")
        }
        let converter: AVAudioConverter
        if let cachedSourceFormat, cachedSourceFormat == sourceFormat, let cachedConverter {
            converter = cachedConverter
        } else {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw DikteError.message("Mikrofon sesi 16 kHz mono biçimine dönüştürülemedi.")
            }
            cachedSourceFormat = sourceFormat
            cachedConverter = newConverter
            cachedOutputBuffer = nil
            converter = newConverter
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 16)
        let output: AVAudioPCMBuffer
        if let cachedOutputBuffer, cachedOutputBuffer.frameCapacity >= capacity {
            output = cachedOutputBuffer
        } else if let newBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) {
            cachedOutputBuffer = newBuffer
            output = newBuffer
        } else {
            throw DikteError.message("Dönüştürülmüş ses tamponu oluşturulamadı.")
        }
        output.frameLength = 0
        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputState.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else {
            throw DikteError.message("Mikrofon dönüştürücüsü ses üretmedi.")
        }
        return output
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let layout = format.isInterleaved ? "interleaved" : "non-interleaved"
        return String(format: "%.0f Hz · %d kanal · %@", format.sampleRate,
                      format.channelCount, layout)
    }
}

private final class CaptureSessionDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.turkerdenizer.dikte.audio-session", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var delegate: CaptureOutputDelegate?

    func start(device: AVCaptureDevice, accumulator: SampleAccumulator,
               onFirstSample: @escaping @MainActor @Sendable () -> Void,
               onLevel: @escaping @Sendable (Float) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.stopLocked()
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw DikteError.message("MacBook mikrofonu kayıt oturumuna bağlanamadı.")
                    }
                    session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    let delegate = CaptureOutputDelegate(accumulator: accumulator)
                    delegate.onFirstSample = onFirstSample
                    delegate.onLevel = onLevel
                    output.setSampleBufferDelegate(delegate, queue: delegate.queue)
                    guard session.canAddOutput(output) else {
                        throw DikteError.message("Mikrofon verisi kayıt oturumundan alınamadı.")
                    }
                    session.addOutput(output)
                    session.commitConfiguration()
                    self.session = session
                    self.delegate = delegate
                    session.startRunning()
                    guard session.isRunning else {
                        self.stopLocked()
                        throw DikteError.message("Mikrofon kayıt oturumu başlatılamadı.")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopLocked()
                continuation.resume()
            }
        }
    }

    func stopSoon() { queue.async { self.stopLocked() } }

    private func stopLocked() {
        let sampleQueue = delegate?.queue
        session?.stopRunning()
        sampleQueue?.sync { }
        session = nil
        delegate = nil
    }
}

/// Resolves the CoreAudio `AudioDeviceID` behind an `AVCaptureDevice`'s unique
/// ID string. `AVAudioEngine` only exposes device selection through the
/// underlying `AudioUnit`, which needs a CoreAudio device ID, not the
/// AVFoundation-level UID string.
private func audioDeviceID(forUniqueID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
          size > 0 else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
        return nil
    }
    for id in ids {
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer -> OSStatus in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { raw in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, raw)
            }
        }
        if status == noErr, let deviceUID = cfUID as String?, deviceUID == uid { return id }
    }
    return nil
}

struct AudioCapture: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
    let diagnostics: AudioDiagnostics

    var callbackCount: Int { diagnostics.callbackCount }
    var deviceName: String { diagnostics.deviceName }

    init(samples: [Float], sampleRate: Double, duration: TimeInterval, callbackCount: Int = 0,
         deviceName: String = "Test", diagnostics: AudioDiagnostics? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.diagnostics = diagnostics ?? AudioDiagnostics(deviceName: deviceName,
                                                            callbackCount: callbackCount,
                                                            sampleCount: samples.count)
    }
}

enum AudioPreprocessor {
    static let targetRate = 16_000.0
    /// The lowest level ever treated as speech, regardless of what the room
    /// sounds like. The adaptive threshold below never goes under this, so a
    /// near-silent recording behaves exactly as it did before adaptivity existed.
    static let speechThreshold: Float = 0.008
    static let frameSize = 320
    /// Speech is taken to start this far above the measured noise floor…
    static let noiseFloorMultiplier: Float = 3.0
    /// …but never above this share of the loud end of the recording, so a
    /// recording with no real pauses (where the "floor" is itself speech) can
    /// never raise the threshold high enough to clip the words themselves.
    static let speechLevelCeilingShare: Float = 0.25
    /// Below this separation between the quiet and loud ends there is nothing to
    /// adapt to, and the fixed threshold is used instead.
    static let minimumSeparation: Float = 2.0
    /// Rumble from fans, air conditioning and desk knocks sits below this and
    /// carries no speech: Whisper is trained on 16 kHz mel spectrograms where
    /// this band contributes nothing, but the energy still eats headroom and
    /// inflates every frame's RMS, which is what the voiced-frame detection
    /// below measures.
    static let highPassCutoff = 80.0

    struct Result: Equatable, Sendable {
        let samples: [Float]
        let voicedDuration: TimeInterval
        let noiseFloor: Float
        let threshold: Float

        init(samples: [Float], voicedDuration: TimeInterval, noiseFloor: Float = 0,
             threshold: Float = AudioPreprocessor.speechThreshold) {
            self.samples = samples
            self.voicedDuration = voicedDuration
            self.noiseFloor = noiseFloor
            self.threshold = threshold
        }
    }

    static func prepare(_ capture: AudioCapture) -> Result {
        let converted = highPassed(resample(capture.samples, from: capture.sampleRate, to: targetRate),
                                   sampleRate: targetRate)
        guard !converted.isEmpty else { return Result(samples: [], voicedDuration: 0) }
        let levels = frameLevels(converted)
        let profile = noiseProfile(forFrameLevels: levels)
        var firstVoiced: Int?
        var lastVoiced: Int?
        var voicedFrames = 0
        for (index, level) in levels.enumerated() where level >= profile.threshold {
            let start = index * frameSize
            firstVoiced = firstVoiced ?? start
            lastVoiced = min(start + frameSize, converted.count)
            voicedFrames += 1
        }
        guard let firstVoiced, let lastVoiced else {
            return Result(samples: [], voicedDuration: 0, noiseFloor: profile.noiseFloor,
                          threshold: profile.threshold)
        }
        let padding = Int(targetRate * 0.12)
        let lower = max(0, firstVoiced - padding)
        let upper = min(converted.count, lastVoiced + padding)
        return Result(samples: Array(converted[lower..<upper]),
                      voicedDuration: Double(voicedFrames * frameSize) / targetRate,
                      noiseFloor: profile.noiseFloor, threshold: profile.threshold)
    }

    static func frameLevels(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSize + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frameSize, samples.count)
            var sum: Float = 0
            for value in samples[start..<end] { sum += value * value }
            levels.append(sqrt(sum / Float(max(1, end - start))))
            start = end
        }
        return levels
    }

    /// Picks the level that separates speech from room noise for *this* recording.
    ///
    /// The fixed 0.008 this replaced was an absolute level, so in a room whose
    /// noise floor already sits above it every frame counted as voiced: the
    /// silence trim did nothing and `voicedDuration` — which the caller uses as
    /// the speech-duration signal whenever the VAD does not produce regions —
    /// reported the whole recording as speech. Percentiles are used rather than
    /// the leading samples because a recording need not begin with silence.
    static func noiseProfile(forFrameLevels levels: [Float]) -> (noiseFloor: Float, threshold: Float) {
        guard !levels.isEmpty else { return (0, speechThreshold) }
        let sorted = levels.sorted()
        let noiseFloor = percentile(sorted, 0.10)
        let speechLevel = percentile(sorted, 0.90)
        guard noiseFloor > 0, speechLevel > noiseFloor * minimumSeparation else {
            return (noiseFloor, speechThreshold)
        }
        let candidate = min(noiseFloor * noiseFloorMultiplier, speechLevel * speechLevelCeilingShare)
        return (noiseFloor, max(speechThreshold, candidate))
    }

    private static func percentile(_ sorted: [Float], _ fraction: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    /// A second-order Butterworth high-pass, applied once in the forward
    /// direction. The phase shift it introduces is irrelevant to Whisper, which
    /// consumes a magnitude mel spectrogram.
    static func highPassed(_ samples: [Float], sampleRate: Double,
                           cutoff: Double = highPassCutoff) -> [Float] {
        guard samples.count > 2, sampleRate > 0, cutoff > 0, cutoff < sampleRate / 2 else { return samples }
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2.0 * 0.707_106_781_2)
        let a0 = 1 + alpha
        let b0 = Float(((1 + cosW0) / 2) / a0)
        let b1 = Float((-(1 + cosW0)) / a0)
        let b2 = b0
        let a1 = Float((-2 * cosW0) / a0)
        let a2 = Float((1 - alpha) / a0)

        var output = [Float](repeating: 0, count: samples.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for index in 0..<samples.count {
            let x0 = samples[index]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[index] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }

    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0 else { return [] }
        guard abs(sourceRate - targetRate) >= 0.5 else { return samples }
        let outputCount = Int((Double(samples.count) * targetRate / sourceRate).rounded(.down))
        guard outputCount > 0 else { return [] }
        let step = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let position = Double(index) * step
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}

enum AudioResampler {
    static func to16kHz(_ capture: AudioCapture) -> [Float] {
        AudioPreprocessor.resample(capture.samples, from: capture.sampleRate, to: 16_000)
    }
}

@MainActor
final class AudioRecorder {
    private let driver = CaptureSessionDriver()
    private let accumulator = SampleAccumulator()
    private var startedAt: Date?
    private var restartCount = 0
    private(set) var builtInInputName = "MacBook’un yerleşik mikrofonu"
    private(set) var builtInInputID = ""

    init() {
        if let device = Self.builtInMicrophone() {
            builtInInputName = device.localizedName
            builtInInputID = device.uniqueID
        }
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(restarting: Bool = false,
               onFirstSample: @escaping @MainActor @Sendable () -> Void,
               onLevel: @escaping @Sendable (Float) -> Void) async throws {
        guard let device = Self.builtInMicrophone() else {
            throw DikteError.message("MacBook’un yerleşik mikrofonu bulunamadı; başka giriş aygıtına geçilmedi.")
        }
        if restarting { restartCount += 1 } else { restartCount = 0; startedAt = Date() }
        builtInInputName = device.localizedName
        builtInInputID = device.uniqueID
        accumulator.reset(device: device, restartCount: restartCount)
        try await driver.start(device: device, accumulator: accumulator,
                               onFirstSample: onFirstSample, onLevel: onLevel)
    }

    func stop() async -> AudioCapture {
        await driver.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        return accumulator.take(duration: duration)
    }

    func diagnosticsSnapshot() -> AudioCapture {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return accumulator.snapshot(duration: duration)
    }

    func stopImmediately() {
        driver.stopSoon()
        startedAt = nil
    }

    /// The built-in microphone reports a stable unique ID, so that is matched
    /// first. The display-name fallback that used to be the only rule is
    /// dangerous on its own: it accepts any device whose localized name contains
    /// "macbook", which includes the speakers — "MacBook Pro Hoparlörü",
    /// "MacBook Pro Speakers" — and the discovery session has been observed
    /// listing an output device after Voice Processing I/O has run. Picking one
    /// produces a capture session that starts happily and delivers no audio at
    /// all. The fallback therefore also requires the device to really have input
    /// channels, which is a property of the hardware rather than of its name in
    /// the user's language.
    static let builtInMicrophoneUniqueID = "BuiltInMicrophoneDevice"

    private static func builtInMicrophone() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                                       position: .unspecified).devices
        if let exact = devices.first(where: { $0.uniqueID == builtInMicrophoneUniqueID }) { return exact }
        return devices.first {
            let name = $0.localizedName.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
            guard name.contains("macbook"), !name.contains("iphone") else { return false }
            return deviceHasAudioInput(uniqueID: $0.uniqueID)
        }
    }

    static func deviceHasAudioInput(uniqueID: String) -> Bool {
        guard let deviceID = audioDeviceID(forUniqueID: uniqueID) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}
