import Foundation

struct HTTPResponse: Sendable {
    static let maximumDataSize = 8 * 1_024 * 1_024

    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

actor URLSessionHTTPClient: HTTPDataLoading {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw MusicBrainzError.invalidResponse
        }
        guard response.expectedContentLength <= HTTPResponse.maximumDataSize else {
            bytes.task.cancel()
            throw MusicBrainzError.responseTooLarge
        }

        var data = Data()
        do {
            for try await byte in bytes {
                if data.count.isMultiple(of: 16_384) {
                    try Task.checkCancellation()
                }
                guard data.count < HTTPResponse.maximumDataSize else {
                    throw MusicBrainzError.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()
        } catch {
            bytes.task.cancel()
            throw error
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = String(describing: item.value)
        }
        return HTTPResponse(
            data: data,
            statusCode: response.statusCode,
            headers: headers
        )
    }
}
