import Foundation
import Testing
@testable import SmartScreenshotCore

/// Answers requests in-process from instructions in the URL (`?status=…&body=…` or `?error=…`), so the real
/// URLSession code path is exercised without network access or shared mutable state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        if let code = query["error"].flatMap(Int.init) {
            client.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: query["status"].flatMap(Int.init) ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "3", "Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data((query["body"] ?? "").utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}

@Suite("URLSession transport")
struct URLSessionTransportTests {
    let transport: URLSessionTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }()

    @Test("Returns status, lowercased headers, and body")
    func response() async throws {
        let url = try #require(URL(string: "https://stub.invalid/?status=503&body=%7B%7D"))
        let response = try await transport.send(URLRequest(url: url))
        #expect(response.statusCode == 503)
        #expect(response.headers["retry-after"] == "3")
        #expect(response.body == Data("{}".utf8))
    }

    @Test("Surfaces transport failures as URLError so they can be classified for retry")
    func failure() async throws {
        let url = try #require(URL(string: "https://stub.invalid/?error=\(URLError.Code.timedOut.rawValue)"))
        let error = await #expect(throws: URLError.self) {
            try await transport.send(URLRequest(url: url))
        }
        #expect(error?.code == .timedOut)
    }
}
