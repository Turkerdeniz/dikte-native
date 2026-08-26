@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var diagnostics = AudioDiagnostics()
    private var squaredSum: Double = 0
    private var voicedSamples = 0

    func reset(device: AVCaptureDevice, restartCount: Int) {
        lock.withLock {
            storage.removeAll(keepingCapacity: true)
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
            storage.removeAll(keepingCapacity: true)
            diagnostics = AudioDiagnostics()
            squaredSum = 0
            voicedSamples = 0
            return capture
        }
    }
}

private final class CaptureOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private final class InputState: @unchecked Sendable { var supplied = false }
    let queue = DispatchQueue(label: "com.turkerdenizer.dikte.audio-samples", qos: .userInteractive)
    private let accumulator: SampleAccumulator
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private var cachedSourceFormat: AVAudioFormat?
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceBuffer: AVAudioPCMBuffer?
    private var cachedOutputBuffer: AVAudioPCMBuffer?
    private var deliveredFirstSample = false
    private var lastLevelDelivery = CFAbsoluteTimeGetCurrent()
    var onFirstSample: (@MainActor @Sendable () -> Void)?
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

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
            let now = CFAbsoluteTimeGetCurrent()
            // The waveform is presentation-only. Thirty updates per second keeps bar movement
            // fluid without coupling visual refreshes to the full audio callback rate.
            if now - lastLevelDelivery >= 1.0 / 30.0, let onLevel {
                lastLevelDelivery = now
                let displayLevel = min(1, pow(max(0, rms), 0.45) * 1.8)
                Task { @MainActor in onLevel(displayLevel) }
            }
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
        let inputState = InputState()
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
               onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
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
    static let speechThreshold: Float = 0.008

    struct Result: Equatable, Sendable {
        let samples: [Float]
        let voicedDuration: TimeInterval
    }

    static func prepare(_ capture: AudioCapture) -> Result {
        let converted = resample(capture.samples, from: capture.sampleRate, to: targetRate)
        guard !converted.isEmpty else { return Result(samples: [], voicedDuration: 0) }
        let frameSize = 320
        var firstVoiced: Int?
        var lastVoiced: Int?
        var voicedFrames = 0
        var start = 0
        while start < converted.count {
            let end = min(start + frameSize, converted.count)
            var sum: Float = 0
            for value in converted[start..<end] { sum += value * value }
            let rms = sqrt(sum / Float(max(1, end - start)))
            if rms >= speechThreshold {
                firstVoiced = firstVoiced ?? start
                lastVoiced = end
                voicedFrames += 1
            }
            start = end
        }
        guard let firstVoiced, let lastVoiced else { return Result(samples: [], voicedDuration: 0) }
        let padding = Int(targetRate * 0.12)
        let lower = max(0, firstVoiced - padding)
        let upper = min(converted.count, lastVoiced + padding)
        return Result(samples: Array(converted[lower..<upper]),
                      voicedDuration: Double(voicedFrames * frameSize) / targetRate)
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
               onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
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

    private static func builtInMicrophone() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                         position: .unspecified).devices.first {
            let name = $0.localizedName.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
            return name.contains("macbook") && !name.contains("iphone")
        }
    }
}
