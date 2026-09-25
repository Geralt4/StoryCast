import Foundation
@testable import StoryCast

/// Serves canned Audiobookshelf responses by path and records requests.
/// Tests using it must not run in parallel with each other.
final class ABSStubURLProtocol: URLProtocol {
    struct Response {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    nonisolated(unsafe) static var responses: [String: Response] = [:]
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = [:]
            recordedRequests = []
        }
    }

    /// Stubs a path for every method, or only for `method` when given.
    static func stub(path: String, method: String? = nil, status: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
        let key = method.map { "\($0) \(path)" } ?? path
        lock.withLock { responses[key] = Response(status: status, body: body, headers: headers) }
    }

    static var requests: [URLRequest] { lock.withLock { recordedRequests } }

    static func makeAPI() -> AudiobookshelfAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ABSStubURLProtocol.self]
        return AudiobookshelfAPI(session: URLSession(configuration: config))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.readAll(stream)
        }
        let stub = Self.lock.withLock { () -> Response? in
            Self.recordedRequests.append(recorded)
            return Self.responses["\(recorded.httpMethod ?? "GET") \(url.path)"] ?? Self.responses[url.path]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
