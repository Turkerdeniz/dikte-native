@preconcurrency import Foundation

struct CodexResult: Sendable { let text: String; let threadID: String }

struct CodexEventParser: Sendable {
    private(set) var threadID: String?
    private(set) var messages: [String] = []

    mutating func consume(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "thread.started" { threadID = object["thread_id"] as? String ?? object["threadId"] as? String }
        if type == "item.completed", let item = object["item"] as? [String: Any],
           item["type"] as? String == "agent_message", let text = item["text"] as? String { messages.append(text) }
        if type == "agent_message", let text = object["text"] as? String { messages.append(text) }
    }
}

actor CodexClient {
    private var activeProcess: Process?

    static func executableURL() -> URL? {
        let bundled = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func ask(transcript: String, existingThreadID: String?, onThreadStarted: @escaping @Sendable (String) -> Void) async throws -> CodexResult {
        guard let executable = Self.executableURL() else { throw DikteError.codexUnavailable }
        try FileManager.default.createDirectory(at: AppPaths.codexRuntime, withIntermediateDirectories: true)
        let process = Process(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executable; process.currentDirectoryURL = AppPaths.codexRuntime
        process.standardOutput = stdout; process.standardError = stderr
        let prompt = CodexEditingPrompt.userPrompt(transcript: transcript)
        var arguments = ["exec"]
        if let existingThreadID { arguments += ["resume", existingThreadID] }
        arguments += [
            "-c", CodexEditingPrompt.developerConfigurationOverride,
            "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"",
            "--strict-config", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json", "--color", "never", prompt
        ]
        process.arguments = arguments
        try process.run(); activeProcess = process

        return try await withTaskCancellationHandler(operation: {
            let outputTask = Task { () -> (CodexEventParser, String) in
                var parser = CodexEventParser()
                var completeOutput = ""
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    completeOutput += line + "\n"
                    parser.consume(line: line)
                    if let id = parser.threadID { onThreadStarted(id) }
                }
                return (parser, completeOutput)
            }
            let status = await Self.waitForExit(process)
            let (parser, output) = try await outputTask.value
            activeProcess = nil
            guard status == 0 else {
                let errorData = try? stderr.fileHandleForReading.readToEnd()
                let errorText = errorData.map { String(decoding: $0, as: UTF8.self) } ?? output
                throw DikteError.message(errorText.isEmpty ? "Codex işlemi başarısız oldu." : errorText)
            }
            guard let threadID = parser.threadID ?? existingThreadID, let text = parser.messages.last, !text.isEmpty else {
                throw DikteError.message("Codex geçerli bir metin döndürmedi.")
            }
            return CodexResult(text: text, threadID: threadID)
        }, onCancel: { Task { await self.cancel() } })
    }

    func cancel() {
        guard let process = activeProcess, process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        activeProcess = nil
    }

    private static func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
    }
}
