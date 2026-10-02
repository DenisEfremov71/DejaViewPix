//
//  SimulatedOverload.swift
//  DejaViewPix
//

#if DEBUG
import Foundation

/// Debug-only fault injection: answers the next N requests with HTTP 529 `overloaded_error`
/// without touching the network, then lets requests through. Used to watch the retry
/// backoff in the app. The request (and its key header) is never read or stored.
nonisolated final class SimulatedOverload: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remaining = 0

    /// A session that routes requests through this protocol first.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [SimulatedOverload.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }()

    /// Fails the next `count` requests with 529.
    static func arm(count: Int) {
        lock.withLock { remaining = count }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { remaining > 0 }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.remaining = max(Self.remaining - 1, 0) }

        let body = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded (simulated)"}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 529,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
