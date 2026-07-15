import Foundation

@MainActor final class WorkerClient {
    private let baseURL = URL(string: "http://127.0.0.1:8767")!
    private var process: Process?
    private var logHandle: FileHandle?
    private var startupTask: Task<Void, Error>?

    func ensureRunning() async throws {
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw WorkerError.unavailable("Tiro was closed during worker startup.") }
            try await self.reconcileWorker()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func reconcileWorker() async throws {
        switch await workerState() {
        case .compatible:
            return
        case .incompatible:
            try await stopIncompatibleWorker()
        case .unavailable:
            break
        }
        try await startAndWait()
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
            var environment = ProcessInfo.processInfo.environment
            environment["TIRO_WORKER_TOKEN"] = try workerToken()
            process.environment = environment
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
        request.timeoutInterval = 1_800
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

    func preload(model: DictationModel) async throws {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/preload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Model preload failed with status \(http.statusCode)."
            throw WorkerError.server(message)
        }
    }

    private func isHealthy() async -> Bool {
        await workerState() == .compatible
    }

    private func workerState() async -> WorkerState {
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let status = try? JSONDecoder().decode(WorkerStatus.self, from: data) else {
                return .unavailable
            }
            return status.api_version == 3 ? .compatible : .incompatible
        } catch {
            return .unavailable
        }
    }

    private func stopIncompatibleWorker() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/shutdown"))
        request.httpMethod = "POST"
        request.setValue(try workerToken(), forHTTPHeaderField: "X-Tiro-Worker-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkerError.unavailable("An incompatible local worker is already running.")
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await workerState() == .unavailable { return }
        }
        throw WorkerError.unavailable("The incompatible local worker did not stop.")
    }

    private func workerToken() throws -> String {
        if let token = try? String(contentsOf: AppPaths.workerTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        let token = UUID().uuidString
        try FileManager.default.createDirectory(
            at: AppPaths.workerTokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try token.write(to: AppPaths.workerTokenFile, atomically: true, encoding: .utf8)
        return token
    }

    func stopOwnedWorker() {
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        logHandle = nil
    }
}

private struct WorkerStatus: Decodable {
    let api_version: Int
}

private enum WorkerState {
    case compatible
    case incompatible
    case unavailable
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
