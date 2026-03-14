import XCTest
@testable import StoryCast

nonisolated final class AudiobookshelfAuthTests: XCTestCase {

    // MARK: - Token Storage Tests

    func testSaveAndRetrieveToken() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://test-abs.example.com:13378"
        let token = "test-token-123"
        
        defer {
            Task {
                try? await auth.deleteToken(for: serverURL)
            }
        }
        
        // Save token
        try await auth.saveToken(token, for: serverURL)
        
        // Retrieve token
        let retrieved = await auth.token(for: serverURL)
        XCTAssertEqual(retrieved, token)
    }

    func testTokenForMissingServerReturnsNil() async {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://nonexistent-test.example.com"
        
        let token = await auth.token(for: serverURL)
        XCTAssertNil(token)
    }

    func testDeleteToken() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://test-delete.example.com"
        let token = "test-token-456"
        
        defer {
            Task {
                try? await auth.deleteToken(for: serverURL)
            }
        }
        
        // Save then delete
        try await auth.saveToken(token, for: serverURL)
        try await auth.deleteToken(for: serverURL)
        
        // Verify deletion
        let retrieved = await auth.token(for: serverURL)
        XCTAssertNil(retrieved)
    }

    func testDeleteTokenForNonExistentServerDoesNotThrow() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURL = "https://nonexistent-delete.example.com"
        
        // Should not throw even if token doesn't exist
        try await auth.deleteToken(for: serverURL)
    }

    func testTokenIsolationPerServer() async throws {
        let auth = AudiobookshelfAuth.shared
        let server1 = "https://test-server1.example.com"
        let server2 = "https://test-server2.example.com"
        let token1 = "token-1"
        let token2 = "token-2"
        
        defer {
            Task {
                try? await auth.deleteToken(for: server1)
                try? await auth.deleteToken(for: server2)
            }
        }
        
        try await auth.saveToken(token1, for: server1)
        try await auth.saveToken(token2, for: server2)
        
        let retrieved1 = await auth.token(for: server1)
        let retrieved2 = await auth.token(for: server2)
        
        XCTAssertEqual(retrieved1, token1)
        XCTAssertEqual(retrieved2, token2)
    }

    func testURLNormalizationForKey() async throws {
        let auth = AudiobookshelfAuth.shared
        let serverURLWithSlash = "https://test-normalize.example.com/"
        let serverURLWithoutSlash = "https://test-normalize.example.com"
        let token = "test-token-normalize"
        
        defer {
            Task {
                try? await auth.deleteToken(for: serverURLWithSlash)
            }
        }
        
        // Save with trailing slash
        try await auth.saveToken(token, for: serverURLWithSlash)
        
        // Retrieve without slash should still work (key normalization)
        let retrieved = await auth.token(for: serverURLWithoutSlash)
        XCTAssertEqual(retrieved, token)
    }
}