import Foundation
import whisper

struct SpeechRegion: Equatable, Sendable {
    let startSample: Int
    let endSample: Int
}

struct SpeechChunk: Equatable, Sendable {
    let samples: [Float]
    let sourceStartSample: Int
    let sourceEndSample: Int
    let speechSampleCount: Int

    var speechDuration: TimeInterval {
        Double(speechSampleCount) / Double(SpeechChunkBuilder.sampleRate)
    }
}

struct SpeechSegmentation: Sendable {
    let chunks: [SpeechChunk]
    let regions: [SpeechRegion]
    let segmentCount: Int
    let speechDuration: TimeInterval
}

actor SpeechSegmenter {
    static let sampleRate = 16_000
    private var context: OpaquePointer?
    private var loadedModelURL: URL?

    func segment(samples: [Float], modelURL: URL) throws -> SpeechSegmentation {
        try Task.checkCancellation()
        try load(modelURL: modelURL)
        guard let context else { throw DikteError.message("Konuşma algılama modeli başlatılamadı.") }

        var params = whisper_vad_default_params()
        params.threshold = 0.50
        params.min_speech_duration_ms = 100
        params.min_silence_duration_ms = 400
        params.max_speech_duration_s = Float.greatestFiniteMagnitude
        params.speech_pad_ms = 200
        params.samples_overlap = 0

        let pointer = samples.withUnsafeBufferPointer {
            whisper_vad_segments_from_samples(context, params, $0.baseAddress, Int32($0.count))
        }
        guard let pointer else { throw DikteError.message("Konuşma bölümleri çıkarılamadı.") }
        defer { whisper_vad_free_segments(pointer) }
        try Task.checkCancellation()

        let count = max(0, Int(whisper_vad_segments_n_segments(pointer)))
        var regions: [SpeechRegion] = []
        regions.reserveCapacity(count)
        for index in 0..<count {
            // whisper.cpp stores the standalone VAD boundaries in centiseconds even though
            // the C getter returns Float. Convert 1/100 s to sample indices explicitly.
            let start = Self.sampleIndex(centiseconds: whisper_vad_segments_get_segment_t0(pointer, Int32(index)),
                                         rounding: .down, limit: samples.count)
            let end = Self.sampleIndex(centiseconds: whisper_vad_segments_get_segment_t1(pointer, Int32(index)),
                                       rounding: .up, limit: samples.count)
            if end > start { regions.append(SpeechRegion(startSample: start, endSample: end)) }
        }
        let merged = SpeechChunkBuilder.mergeOverlaps(regions)
        let duration = Double(merged.reduce(0) { $0 + ($1.endSample - $1.startSample) }) / Double(Self.sampleRate)
        return SpeechSegmentation(chunks: SpeechChunkBuilder.makeChunks(samples: samples, regions: merged),
                                  regions: merged, segmentCount: count, speechDuration: duration)
    }

    func unload() {
        if let context { whisper_vad_free(context) }
        context = nil
        loadedModelURL = nil
    }

    nonisolated static func sampleIndex(centiseconds: Float, rounding: FloatingPointRoundingRule,
                                        limit: Int) -> Int {
        let samples = (Double(centiseconds) / 100.0) * Double(sampleRate)
        return max(0, min(limit, Int(samples.rounded(rounding))))
    }

    private func load(modelURL: URL) throws {
        if context != nil, loadedModelURL == modelURL { return }
        unload()
        var params = whisper_vad_default_context_params()
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
        params.use_gpu = false
        context = modelURL.path.withCString { whisper_vad_init_from_file_with_params($0, params) }
        guard context != nil else { throw DikteError.message("Konuşma algılama modeli yüklenemedi.") }
        loadedModelURL = modelURL
    }
}

enum SpeechChunkBuilder {
    static let sampleRate = 16_000
    static let maximumChunkSamples = 20 * sampleRate
    static let separatorSamples = sampleRate / 4
    static let splitOverlapSamples = sampleRate / 4

    static func mergeOverlaps(_ regions: [SpeechRegion]) -> [SpeechRegion] {
        let sorted = regions.filter { $0.endSample > $0.startSample }.sorted { $0.startSample < $1.startSample }
        guard var current = sorted.first else { return [] }
        var result: [SpeechRegion] = []
        for next in sorted.dropFirst() {
            if next.startSample <= current.endSample {
                current = SpeechRegion(startSample: current.startSample, endSample: max(current.endSample, next.endSample))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    static func makeChunks(samples: [Float], regions: [SpeechRegion]) -> [SpeechChunk] {
        let slices = regions.flatMap { split(region: $0, sampleCount: samples.count) }
        var chunks: [SpeechChunk] = []
        var current: [Float] = []
        var sourceStart: Int?
        var sourceEnd = 0
        var speechSampleCount = 0

        func flush() {
            guard let startValue = sourceStart, !current.isEmpty else { return }
            chunks.append(SpeechChunk(samples: current, sourceStartSample: startValue,
                                      sourceEndSample: sourceEnd, speechSampleCount: speechSampleCount))
            current = []
            sourceStart = nil
            sourceEnd = 0
            speechSampleCount = 0
        }

        for region in slices {
            let speech = Array(samples[region.startSample..<region.endSample])
            let separatorCount = current.isEmpty ? 0 : separatorSamples
            if !current.isEmpty, current.count + separatorCount + speech.count > maximumChunkSamples {
                flush()
            }
            if !current.isEmpty { current.append(contentsOf: repeatElement(0, count: separatorSamples)) }
            if sourceStart == nil { sourceStart = region.startSample }
            sourceEnd = max(sourceEnd, region.endSample)
            speechSampleCount += speech.count
            current.append(contentsOf: speech)
        }
        flush()
        return chunks
    }

    private static func split(region: SpeechRegion, sampleCount: Int) -> [SpeechRegion] {
        let lower = max(0, min(region.startSample, sampleCount))
        let upper = max(lower, min(region.endSample, sampleCount))
        guard upper > lower else { return [] }
        var result: [SpeechRegion] = []
        var start = lower
        while start < upper {
            let end = min(start + maximumChunkSamples, upper)
            result.append(SpeechRegion(startSample: start, endSample: end))
            guard end < upper else { break }
            start = max(start + 1, end - splitOverlapSamples)
        }
        return result
    }
}

enum TranscriptAssembler {
    static func join(_ parts: [String]) -> String {
        var words: [String] = []
        for part in parts {
            let next = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !next.isEmpty else { continue }
            let overlap = overlapCount(words, next)
            words.append(contentsOf: next.dropFirst(overlap))
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func overlapCount(_ left: [String], _ right: [String]) -> Int {
        let limit = min(8, left.count, right.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1) {
            let lhs = left.suffix(count).map(normalize)
            let rhs = right.prefix(count).map(normalize)
            if lhs == rhs { return count }
        }
        return 0
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}
