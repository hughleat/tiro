import Foundation

@MainActor final class WorkerProcess {
    private static let supportedAPIVersion = 6
    private let baseURL: URL
    private let transport: WorkerTransport
    private let tokenFile: URL
    private let reconcileOverride: (@MainActor () async throws -> Void)?
    private var process: Process?
    private var logHandle: FileHandle?
    private var startupTask: Task<Void, Error>?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8767")!,
        transport: WorkerTransport = WorkerTransport(),
        tokenFile: URL = AppPaths.workerTokenFile,
        reconcileOverride: (@MainActor () async throws -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenFile = tokenFile
        self.reconcileOverride = reconcileOverride
    }

    func ensureRunning() async throws {
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                throw WorkerError.unavailable("Tiro was closed during worker startup.")
            }
            if let reconcileOverride = self.reconcileOverride {
                try await reconcileOverride()
            } else {
                try await self.reconcileWorker()
            }
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    func authenticationToken() throws -> String {
        if PrivateFilePermissions.itemExists(at: tokenFile) {
            try PrivateFilePermissions.repairItem(at: tokenFile)
            let token = try String(contentsOf: tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }

        let token = UUID().uuidString
        try PrivateFilePermissions.write(Data(token.utf8), to: tokenFile)
        return token
    }

    func stopOwnedWorker() {
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        logHandle = nil
    }

    private func reconcileWorker() async throws {
        try preparePrivateStorage()
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

    private func preparePrivateStorage() throws {
        try PrivateFilePermissions.ensureDirectory(at: AppPaths.applicationSupportDirectory)
        try PrivateFilePermissions.repairTree(at: AppPaths.dataDirectory)
        try PrivateFilePermissions.ensureDirectory(at: AppPaths.logsDirectory)
        try PrivateFilePermissions.ensureFile(at: AppPaths.workerLog)
    }

    private func startAndWait() async throws {
        do {
            try await launchAndWait()
        } catch {
            if process?.isRunning == true { process?.terminate() }
            process = nil
            try? logHandle?.close()
            logHandle = nil
            throw error
        }
    }

    private func launchAndWait() async throws {
        if process?.isRunning != true {
            let embeddedWorker = AppPaths.embeddedWorkerExecutable
            let executableURL: URL
            let arguments: [String]
            if FileManager.default.isExecutableFile(atPath: embeddedWorker.path) {
                executableURL = embeddedWorker
                arguments = []
            } else {
                let pythonURL = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
                guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                    throw WorkerError.runtimeMissing(pythonURL.path)
                }
                executableURL = pythonURL
                arguments = [AppPaths.developmentWorkerEntryPoint.path]
            }

            let handle = try FileHandle(forWritingTo: AppPaths.workerLog)
            try handle.seekToEnd()
            logHandle = handle
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = AppPaths.applicationSupportDirectory
            var environment = AppPaths.workerEnvironment()
            environment["TIRO_WORKER_TOKEN"] = try authenticationToken()
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            self.process = process
        }

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await workerState() == .compatible { return }
            if process?.isRunning == false { break }
        }
        throw WorkerError.unavailable(recentWorkerLog())
    }

    func workerState() async -> WorkerState {
        do {
            var statusRequest = URLRequest(url: baseURL.appendingPathComponent("api/status"))
            statusRequest.setValue(
                try authenticationToken(),
                forHTTPHeaderField: "X-Tiro-Worker-Token"
            )
            let (data, response) = try await transport.response(for: statusRequest)
            guard response.statusCode == 200,
                  let status = try? JSONDecoder().decode(WorkerStatus.self, from: data) else {
                return .unavailable
            }
            guard status.api_version == Self.supportedAPIVersion,
                  URL(fileURLWithPath: status.history_file).standardizedFileURL
                    == AppPaths.historyFile.standardizedFileURL else {
                return .incompatible
            }

            var authRequest = URLRequest(url: baseURL.appendingPathComponent("api/models"))
            authRequest.setValue(
                try authenticationToken(),
                forHTTPHeaderField: "X-Tiro-Worker-Token"
            )
            let (_, authResponse) = try await transport.response(for: authRequest)
            return authResponse.statusCode == 200 ? .compatible : .incompatible
        } catch {
            return .unavailable
        }
    }

    func stopIncompatibleWorker() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/shutdown"))
        request.httpMethod = "POST"
        request.setValue(
            try authenticationToken(),
            forHTTPHeaderField: "X-Tiro-Worker-Token"
        )
        let (_, response) = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw WorkerError.unavailable("An incompatible local worker is already running.")
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await workerState() == .unavailable { return }
        }
        throw WorkerError.unavailable("The incompatible local worker did not stop.")
    }

    private func recentWorkerLog() -> String {
        guard let data = try? Data(contentsOf: AppPaths.workerLog),
              let contents = String(data: data, encoding: .utf8) else { return "" }
        return contents.split(separator: "\n").suffix(3).joined(separator: " ")
    }
}

private struct WorkerStatus: Decodable {
    let api_version: Int
    let history_file: String
}

enum WorkerState: Equatable {
    case compatible
    case incompatible
    case unavailable
}
