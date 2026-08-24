import CryptoKit
import Foundation

@MainActor
final class ModelStore: ObservableObject {
    enum Status: Equatable {
        case missing, downloading(Double), verifying, ready, failed(String)
    }
    static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    static let expectedSHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    static let expectedSize: Int64 = 574_041_195

    @Published private(set) var status: Status = .missing
    @Published var isLoaded = false
    private var downloadTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        guard FileManager.default.fileExists(atPath: AppPaths.model.path),
              let size = (try? AppPaths.model.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
              size == Self.expectedSize else { status = .missing; return }
        status = .verifying
        Task {
            do {
                let digest = try await Self.sha256(of: AppPaths.model)
                status = digest == Self.expectedSHA256 ? .ready : .failed(DikteError.modelInvalid.localizedDescription)
            } catch { status = .failed(error.localizedDescription) }
        }
    }

    func download() {
        guard downloadTask == nil else { return }
        status = .downloading(0)
        downloadTask = Task {
            do {
                try FileManager.default.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: AppPaths.modelPart)
                let (temporary, response) = try await URLSession.shared.download(from: Self.downloadURL)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw DikteError.message("Model sunucusu geçersiz yanıt verdi.")
                }
                try FileManager.default.moveItem(at: temporary, to: AppPaths.modelPart)
                status = .verifying
                let digest = try await Self.sha256(of: AppPaths.modelPart)
                try Task.checkCancellation()
                guard digest == Self.expectedSHA256 else { throw DikteError.modelInvalid }
                try? FileManager.default.removeItem(at: AppPaths.model)
                try FileManager.default.moveItem(at: AppPaths.modelPart, to: AppPaths.model)
                status = .ready
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: AppPaths.modelPart); status = .missing
            } catch {
                try? FileManager.default.removeItem(at: AppPaths.modelPart); status = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func cancelDownload() { downloadTask?.cancel(); downloadTask = nil }
    func deleteModel() {
        cancelDownload(); try? FileManager.default.removeItem(at: AppPaths.model); try? FileManager.default.removeItem(at: AppPaths.modelPart)
        status = .missing; isLoaded = false
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let data = try? handle.read(upToCount: 4 * 1024 * 1024)
                guard let data, !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }) {}
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
