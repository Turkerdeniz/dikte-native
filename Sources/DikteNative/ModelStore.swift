import CryptoKit
import Darwin
import Foundation

struct ModelVerificationReceipt: Codable, Equatable, Sendable {
    let size: Int64
    let modificationTime: TimeInterval
    let sha256: String

    static func make(for url: URL, sha256: String) throws -> ModelVerificationReceipt {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else {
            throw DikteError.modelInvalid
        }
        return ModelVerificationReceipt(size: size,
                                        modificationTime: date.timeIntervalSinceReferenceDate,
                                        sha256: sha256)
    }

    func matches(file url: URL, expectedSize: Int64, expectedSHA256: String) -> Bool {
        guard size == expectedSize, sha256 == expectedSHA256,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize,
              let date = attributes[.modificationDate] as? Date else { return false }
        return abs(date.timeIntervalSinceReferenceDate - modificationTime) < 0.001
    }
}

enum StreamingFileSHA256 {
    static func digest(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let capacity = 4 * 1024 * 1024
            let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity,
                                                           alignment: MemoryLayout<UInt64>.alignment)
            defer { storage.deallocate() }
            var hasher = SHA256()
            while true {
                let count = Darwin.read(handle.fileDescriptor, storage, capacity)
                if count < 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if count == 0 { break }
                autoreleasepool {
                    let bytes = Data(bytesNoCopy: storage, count: count, deallocator: .none)
                    hasher.update(data: bytes)
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

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
        if let data = try? Data(contentsOf: AppPaths.modelVerificationReceipt),
           let receipt = try? JSONDecoder().decode(ModelVerificationReceipt.self, from: data),
           receipt.matches(file: AppPaths.model, expectedSize: Self.expectedSize,
                           expectedSHA256: Self.expectedSHA256) {
            status = .ready
            return
        }
        status = .verifying
        Task {
            do {
                let digest = try await Self.sha256(of: AppPaths.model)
                guard digest == Self.expectedSHA256 else {
                    try? FileManager.default.removeItem(at: AppPaths.modelVerificationReceipt)
                    status = .failed(DikteError.modelInvalid.localizedDescription)
                    return
                }
                try persistVerificationReceipt()
                status = .ready
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
                try persistVerificationReceipt()
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
        try? FileManager.default.removeItem(at: AppPaths.modelVerificationReceipt)
        status = .missing; isLoaded = false
    }

    private static func sha256(of url: URL) async throws -> String {
        try await StreamingFileSHA256.digest(of: url)
    }

    private func persistVerificationReceipt() throws {
        let receipt = try ModelVerificationReceipt.make(for: AppPaths.model,
                                                        sha256: Self.expectedSHA256)
        let data = try JSONEncoder().encode(receipt)
        try FileManager.default.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
        try data.write(to: AppPaths.modelVerificationReceipt, options: .atomic)
    }
}
