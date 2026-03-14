import XCTest
@testable import StoryCast

nonisolated final class AudiobookshelfURLValidatorTests: XCTestCase {

    // MARK: - Base URL Normalization

    func testNormalizedBaseURLString_HTTPSWithPort() throws {
        let result = try AudiobookshelfURLValidator.normalizedBaseURLString(from: "abs.example.com:13378/")
        XCTAssertEqual(result, "https://abs.example.com:13378")
    }

    func testNormalizedBaseURLString_HTTPSWithoutPort() throws {
        let result = try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://abs.example.com")
        XCTAssertEqual(result, "https://abs.example.com")
    }

    func testNormalizedBaseURLString_AddsHTTPSWhenMissing() throws {
        let result = try AudiobookshelfURLValidator.normalizedBaseURLString(from: "abs.example.com")
        XCTAssertEqual(result, "https://abs.example.com")
    }

    func testNormalizedBaseURLString_RejectsHTTP() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "http://abs.example.com")) { error in
            guard case APIError.insecureConnection = error else {
                return XCTFail("Expected insecure connection error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsURLWithPath() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://abs.example.com/library")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsURLWithQuery() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://abs.example.com?test=1")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsURLWithFragment() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://abs.example.com#section")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsURLWithCredentials() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://user:pass@abs.example.com")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsEmptyString() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testNormalizedBaseURLString_RejectsWhitespaceOnly() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "   ")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    // MARK: - Streaming URL Validation

    func testValidatedStreamingURL_RelativePath() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com:13378",
            contentURL: "/api/items/123/file.mp3"
        )
        XCTAssertEqual(url.absoluteString, "https://abs.example.com:13378/api/items/123/file.mp3")
    }

    func testValidatedStreamingURL_RelativePathWithoutLeadingSlash() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com",
            contentURL: "api/items/123/file.mp3"
        )
        XCTAssertEqual(url.absoluteString, "https://abs.example.com/api/items/123/file.mp3")
    }

    func testValidatedStreamingURL_AbsoluteHTTPSSameOrigin() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com:13378",
            contentURL: "https://abs.example.com:13378/api/items/123/file.mp3"
        )
        XCTAssertEqual(url.absoluteString, "https://abs.example.com:13378/api/items/123/file.mp3")
    }

    func testValidatedStreamingURL_RejectsCrossOriginHTTP() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "http://abs.example.com/api/items/123/file.mp3"
            )
        ) { error in
            guard case APIError.insecureConnection = error else {
                return XCTFail("Expected insecure connection error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsCrossOriginHTTPS() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "https://evil.example.com/api/items/123/file.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsDoubleSlashProtocolRelative() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "//evil.example.com/file.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsPathTraversal() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/../etc/passwd"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsPathTraversalWithDot() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/./secret.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsTokenInQuery() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/123/file.mp3?token=secret"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsTokenCaseInsensitive() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/123/file.mp3?TOKEN=secret"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsEmptyContentURL() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: ""
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_AllowsOtherQueryParameters() throws {
        // Non-token query parameters should be allowed
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com",
            contentURL: "/api/items/123/file.mp3?quality=high&format=mp3"
        )
        XCTAssertEqual(url.absoluteString, "https://abs.example.com/api/items/123/file.mp3?quality=high&format=mp3")
    }

    func testValidatedStreamingURL_RejectsFragment() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/123/file.mp3#section"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_RejectsURLWithCredentialsInContentURL() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "https://user:pass@abs.example.com/file.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_SameOriginDifferentPort() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com:13378",
            contentURL: "https://abs.example.com:13378/api/items/123/file.mp3"
        )
        XCTAssertEqual(url.absoluteString, "https://abs.example.com:13378/api/items/123/file.mp3")
    }

    func testValidatedStreamingURL_DifferentPortRejected() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com:13378",
                contentURL: "https://abs.example.com:8080/api/items/123/file.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testValidatedStreamingURL_DefaultsHTTPSPort443() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com",
            contentURL: "https://abs.example.com:443/api/items/123/file.mp3"
        )
        // Port 443 is preserved in the URL even though it's the default
        XCTAssertEqual(url.absoluteString, "https://abs.example.com:443/api/items/123/file.mp3")
    }

    // MARK: - Same Origin Helper
    // Note: sameOrigin, effectivePort, isSafePath, and hasSensitiveQueryItem are private
    // implementation details. Their behavior is tested indirectly through validatedStreamingURL tests.
}