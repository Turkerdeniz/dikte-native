import CryptoKit
import Foundation

@MainActor
final class VADModelStore: ObservableObject {
    enum Status: Equatable {
        case verifying, ready, failed(String)
    }

    static let expectedSHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
    static let expectedSize = 885_098
    static var bundledURL: URL? {
        Bundle.module.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")
    }

    @Published private(set) var status: Status = .verifying
    private var validatedURL: URL?
    private var validationTask: Task<URL, Error>?

    init() { Task { _ = try? await modelURL() } }

    func modelURL() async throws -> URL {
        if let validatedURL { return validatedURL }
        if let validationTask { return try await validationTask.value }
        guard let url = Self.bundledURL else {
            let error = DikteError.message("Konuşma algılama modeli uygulama paketinde bulunamadı.")
            status = .failed(error.localizedDescription)
            throw error
        }
        let expectedSize = Self.expectedSize
        let expectedSHA256 = Self.expectedSHA256
        let task = Task.detached(priority: .utility) { () throws -> URL in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == expectedSize else { throw DikteError.modelInvalid }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256 else { throw DikteError.modelInvalid }
            return url
        }
        validationTask = task
        do {
            let result = try await task.value
            validatedURL = result
            validationTask = nil
            status = .ready
            return result
        } catch {
            validationTask = nil
            status = .failed("Konuşma algılama modeli doğrulanamadı.")
            throw error
        }
    }
}
