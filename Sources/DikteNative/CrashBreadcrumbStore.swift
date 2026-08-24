import Foundation

struct CrashBreadcrumb: Codable, Equatable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    var stage: String
    var modelLoaded: Bool
    var memoryPressureLevel: MemoryPressureLevel
}

final class CrashBreadcrumbStore {
    private let fileURL: URL
    private let encoder: JSONEncoder

    init(fileURL: URL = AppPaths.crashBreadcrumbFile) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func recover() -> CrashBreadcrumb? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CrashBreadcrumb.self, from: data)
    }

    func begin(stage: String, modelLoaded: Bool, memoryPressureLevel: MemoryPressureLevel) {
        persist(CrashBreadcrumb(sessionID: UUID(), startedAt: Date(), stage: stage,
                                modelLoaded: modelLoaded, memoryPressureLevel: memoryPressureLevel))
    }

    func update(stage: String? = nil, modelLoaded: Bool? = nil,
                memoryPressureLevel: MemoryPressureLevel? = nil) {
        guard var breadcrumb = recover() else { return }
        if let stage { breadcrumb.stage = stage }
        if let modelLoaded { breadcrumb.modelLoaded = modelLoaded }
        if let memoryPressureLevel { breadcrumb.memoryPressureLevel = memoryPressureLevel }
        persist(breadcrumb)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist(_ breadcrumb: CrashBreadcrumb) {
        guard let data = try? encoder.encode(breadcrumb) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Crash breadcrumb write failed: \(error)")
        }
    }
}
