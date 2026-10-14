import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Sends one HTTP request. Tests substitute a fake so they never touch the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// `URLSession` transport using an ephemeral session: no cookies, credential storage, or response cache.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields {
            headers[name.lowercased()] = value
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
