import Foundation

final class WorkerClient {
    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var process: Process?
    private var logHandle: FileHandle?
    private var startupTask: Task<Void, Error>?

    func ensureRunning() async throws {
        if await isHealthy() { return }

        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw WorkerError.unavailable("Tiro was closed during worker startup.") }
            try await self.startAndWait()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func startAndWait() async throws {
        if process?.isRunning != true {
            let pythonURL = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
            guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                throw WorkerError.runtimeMissing(pythonURL.path)
            }

            try FileManager.default.createDirectory(
                at: AppPaths.workerLog.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: AppPaths.workerLog.path) {
                FileManager.default.createFile(atPath: AppPaths.workerLog.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: AppPaths.workerLog)
            try handle.seekToEnd()
            logHandle = handle

            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [AppPaths.projectRoot.appendingPathComponent("app.py").path]
            process.currentDirectoryURL = AppPaths.projectRoot
            process.environment = ProcessInfo.processInfo.environment
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            self.process = process
        }

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await isHealthy() { return }
            if process?.isRunning == false { break }
        }
        throw WorkerError.unavailable(recentWorkerLog())
    }

    func transcribe(wavURL: URL, model: DictationModel) async throws -> TranscriptionResponse {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/transcribe"))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        request.httpBody = try Data(contentsOf: wavURL)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Transcription failed with status \(http.statusCode)."
            throw WorkerError.server(message)
        }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    private func isHealthy() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func stopOwnedWorker() {
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        logHandle = nil
    }
}

enum WorkerError: LocalizedError {
    case unavailable(String)
    case runtimeMissing(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail.isEmpty
                ? "The local transcription worker did not start."
                : "The local transcription worker did not start: \(detail)"
        case .runtimeMissing(let path): return "The Python runtime is missing at \(path)."
        case .invalidResponse: return "The transcription worker returned an invalid response."
        case .server(let message): return message
        }
    }
}

private extension WorkerClient {
    func recentWorkerLog() -> String {
        guard let data = try? Data(contentsOf: AppPaths.workerLog),
              let contents = String(data: data, encoding: .utf8) else { return "" }
        return contents.split(separator: "\n").suffix(3).joined(separator: " ")
    }
}
