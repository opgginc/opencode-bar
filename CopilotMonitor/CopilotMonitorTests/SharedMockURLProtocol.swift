import Foundation
import XCTest

/// Shared URLProtocol stub for provider fetch tests.
///
/// Each test file historically carried its own byte-identical copy of this
/// stub. New tests should reuse this one instead of adding another copy.
final class SharedMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = SharedMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension XCTestCase {
    func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func resetMockURLProtocol() {
        SharedMockURLProtocol.requestHandler = nil
    }
}
