import Foundation
import whisper

struct WhisperTranscript: Equatable, Sendable {
    let text: String
    let meanTokenProbability: Float
    let lowConfidenceTokenRatio: Float
    let tokenCount: Int
    let detectedLanguage: String?

    init(text: String, meanTokenProbability: Float, lowConfidenceTokenRatio: Float = 0,
         tokenCount: Int, detectedLanguage: String? = nil) {
        self.text = text
        self.meanTokenProbability = meanTokenProbability
        self.lowConfidenceTokenRatio = lowConfidenceTokenRatio
        self.tokenCount = tokenCount
        self.detectedLanguage = detectedLanguage
    }
}

enum ChunkAcceptancePolicy {
    static let weakTokenThreshold: Float = 0.45
    static func issue(for transcript: WhisperTranscript, speechDuration: TimeInterval) -> String? {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || transcript.tokenCount == 0 { return "Parça boş döndü." }
        if !TranscriptionPolicy.accepts(text, voicedDuration: speechDuration) {
            return "Parça sessizlik veya halüsinasyon kontrolünden geçemedi."
        }
        if speechDuration >= 2, Double(transcript.tokenCount) / speechDuration < 0.35 {
            return "Konuşma süresine göre olağan dışı kısa metin üretildi."
        }
        return nil
    }
}

actor WhisperEngine {
    static let threadCount: Int32 = 4
    private var context: OpaquePointer?
    private var loadedModelURL: URL?

    func load(modelURL: URL) throws {
        if context != nil, loadedModelURL == modelURL { return }
        if let context { whisper_free(context) }
        context = nil
        loadedModelURL = nil
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw DikteError.modelMissing }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        context = modelURL.path.withCString { whisper_init_from_file_with_params($0, params) }
        guard context != nil else { throw DikteError.modelInvalid }
        loadedModelURL = modelURL
    }

    func transcribe(samples: [Float], language: RecognitionLanguage, promptTerms: [String] = [],
                    noSpeechThreshold: Float = 0.55,
                    threadCount: Int32 = WhisperEngine.threadCount) throws -> WhisperTranscript {
        let result = try transcribeSingle(samples: samples, languageCode: language.whisperCode,
                                          detectLanguage: language == .automatic,
                                          promptTerms: promptTerms, noSpeechThreshold: noSpeechThreshold,
                                          threadCount: threadCount)
        return WhisperTranscript(text: result.text, meanTokenProbability: result.meanTokenProbability,
                                 lowConfidenceTokenRatio: result.tokenCount > 0
                                    ? Float(result.lowConfidenceTokenCount) / Float(result.tokenCount) : 0,
                                 tokenCount: result.tokenCount, detectedLanguage: result.detectedLanguage)
    }

    func transcribe(chunks: [[Float]], language: RecognitionLanguage, promptTerms: [String] = []) throws -> WhisperTranscript {
        guard context != nil else { throw DikteError.modelMissing }
        var detectedLanguage = language.whisperCode
        var parts: [String] = []
        var weightedProbability: Float = 0
        var tokenCount = 0
        var lowConfidenceTokenCount = 0
        for chunk in chunks where !chunk.isEmpty {
            try Task.checkCancellation()
            let result = try transcribeSingle(samples: chunk, languageCode: detectedLanguage,
                                              detectLanguage: language == .automatic && detectedLanguage == nil,
                                              promptTerms: promptTerms)
            parts.append(result.text)
            weightedProbability += result.meanTokenProbability * Float(result.tokenCount)
            tokenCount += result.tokenCount
            lowConfidenceTokenCount += result.lowConfidenceTokenCount
            if detectedLanguage == nil { detectedLanguage = result.detectedLanguage }
        }
        return WhisperTranscript(text: TranscriptAssembler.join(parts),
                                 meanTokenProbability: tokenCount > 0 ? weightedProbability / Float(tokenCount) : 0,
                                 lowConfidenceTokenRatio: tokenCount > 0 ? Float(lowConfidenceTokenCount) / Float(tokenCount) : 0,
                                 tokenCount: tokenCount, detectedLanguage: detectedLanguage)
    }

    private func transcribeSingle(samples: [Float], languageCode: String?, detectLanguage: Bool,
                                  promptTerms: [String], noSpeechThreshold: Float = 0.55,
                                  threadCount: Int32 = WhisperEngine.threadCount) throws -> (text: String, detectedLanguage: String?, meanTokenProbability: Float, tokenCount: Int, lowConfidenceTokenCount: Int) {
        guard let context else { throw DikteError.modelMissing }
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = min(threadCount, Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.detect_language = detectLanguage
        params.beam_search.beam_size = 5
        params.beam_search.patience = 1
        params.suppress_blank = true
        params.suppress_nst = true
        params.no_speech_thold = noSpeechThreshold
        params.temperature = 0
        params.temperature_inc = 0.2

        let prompt = promptTerms.isEmpty ? nil : "Özel isimler: " + promptTerms.joined(separator: ", ") + "."
        let run: (UnsafePointer<CChar>?) -> Int32 = { promptPointer in
            params.initial_prompt = promptPointer
            if let code = languageCode {
                return code.withCString { languagePointer in
                    params.language = languagePointer
                    return samples.withUnsafeBufferPointer {
                        whisper_full(context, params, $0.baseAddress, Int32($0.count))
                    }
                }
            }
            params.language = nil
            return samples.withUnsafeBufferPointer {
                whisper_full(context, params, $0.baseAddress, Int32($0.count))
            }
        }
        let result = prompt.map { value in value.withCString(run) } ?? run(nil)
        try Task.checkCancellation()
        guard result == 0 else { throw DikteError.transcriptionFailed }
        let count = whisper_full_n_segments(context)
        var text = ""
        var probabilitySum: Float = 0
        var probabilityCount = 0
        var lowConfidenceTokenCount = 0
        let endOfTextToken = whisper_token_eot(context)
        for index in 0..<count {
            if let pointer = whisper_full_get_segment_text(context, index) { text += String(cString: pointer) }
            let count = whisper_full_n_tokens(context, index)
            for tokenIndex in 0..<count {
                guard whisper_full_get_token_id(context, index, tokenIndex) < endOfTextToken else { continue }
                let probability = whisper_full_get_token_p(context, index, tokenIndex)
                if probability.isFinite, probability > 0 {
                    probabilitySum += probability
                    probabilityCount += 1
                    if probability < ChunkAcceptancePolicy.weakTokenThreshold { lowConfidenceTokenCount += 1 }
                }
            }
        }
        let languageID = whisper_full_lang_id(context)
        let detected = languageID >= 0 ? whisper_lang_str(languageID).map { String(cString: $0) } : nil
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), detected,
                probabilityCount > 0 ? probabilitySum / Float(probabilityCount) : 0,
                probabilityCount, lowConfidenceTokenCount)
    }

    func unload() {
        if let context { whisper_free(context) }
        context = nil
        loadedModelURL = nil
    }
}
