import XCTest
import Foundation
@testable import StoryCast

/// Regression tests for the 401 token cleanup path in `AudiobookshelfAPI`.
///
/// Background: the original implementation derived the keychain key from
/// `response.url?.host`, producing a string like "abs.example.com" that could
/// not match the saved key "https://abs.example.com:13378" used by
/// `AudiobookshelfAuth`. The cleanup also ran in a fire-and-forget Task, so
/// the Keychain entry was never actually removed before the 401 propagated.
///
/// These tests use a `URLProtocol` stub to return a synthetic 401 from a
/// port-bearing server URL, then verify the corresponding token is removed
/// from the Keychain.
final class UnauthorizedTokenCleanupTests: XCTestCase {

    // MARK: - URLProtocol Stub

    private final class UnauthorizedStubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"unauthorized\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: - Helpers

    private func makeStubbedAPI() -> AudiobookshelfAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnauthorizedStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return AudiobookshelfAPI(session: session)
    }

    // MARK: - Tests

    func test401RemovesTokenForServerWithCustomPort() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://abs-cleanup-test.example.com:13378"
        let token = "test-token-cleanup-port"
        let api = makeStubbedAPI()

        defer {
            Task { try? await auth.deleteToken(for: serverURL) }
        }

        // Save a token for the port-bearing server.
        try await auth.saveToken(token, for: serverURL)
        let savedToken = await auth.token(for: serverURL)
        XCTAssertEqual(savedToken, token, "Pre-condition: token should be saved before triggering 401")

        // Trigger a 401 by calling any authenticated endpoint. The /api/me path
        // is the same one used by validateServerAccess at startup.
        do {
            _ = try await api.authorize(baseURL: serverURL, token: token)
            XCTFail("Expected APIError.unauthorized, but authorize() succeeded")
        } catch APIError.unauthorized {
            // Expected
        }

        // The fix: token must be removed from the Keychain after the 401.
        // Before the fix, this would still return `token` because the cleanup
        // used a wrong key ("abs-cleanup-test.example.com" instead of the full
        // origin) and ran in a fire-and-forget Task.
        let remainingToken = await auth.token(for: serverURL)
        XCTAssertNil(
            remainingToken,
            "401 response should remove the token for \(serverURL) from the Keychain, but it was still present"
        )
    }

    func test401RemovesTokenForServerWithDefaultPort() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://abs-cleanup-default-port.example.com"
        let token = "test-token-cleanup-default"
        let api = makeStubbedAPI()

        defer {
            Task { try? await auth.deleteToken(for: serverURL) }
        }

        try await auth.saveToken(token, for: serverURL)

        do {
            _ = try await api.authorize(baseURL: serverURL, token: token)
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {}

        let remainingToken = await auth.token(for: serverURL)
        XCTAssertNil(remainingToken, "401 should remove token even when no custom port is in use")
    }

    func test401DoesNotAffectTokensForOtherServers() async throws {
        let auth = AudiobookshelfAuth.shared
        let targetServer = "https://abs-cleanup-isolation-target.example.com:9001"
        let otherServer = "https://abs-cleanup-isolation-other.example.com:9002"
        let targetToken = "target-token"
        let otherToken = "other-token"
        let api = makeStubbedAPI()

        defer {
            Task {
                try? await auth.deleteToken(for: targetServer)
                try? await auth.deleteToken(for: otherServer)
            }
        }

        try await auth.saveToken(targetToken, for: targetServer)
        try await auth.saveToken(otherToken, for: otherServer)

        // 401 only against target server
        do {
            _ = try await api.authorize(baseURL: targetServer, token: targetToken)
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {}

        let remainingTarget = await auth.token(for: targetServer)
        let remainingOther = await auth.token(for: otherServer)

        XCTAssertNil(remainingTarget, "Target server token should be removed by 401")
        XCTAssertEqual(remainingOther, otherToken, "Other server token must not be affected by 401 on a different server")
    }
}
