import Foundation

struct WorkerTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkerError.invalidResponse
        }
        return (data, http)
    }

    func send(_ request: URLRequest, operation: String) async throws -> Data {
        let (data, response) = try await response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "\(operation) failed with status \(response.statusCode)."
            throw WorkerError.server(message)
        }
        return data
    }
}
