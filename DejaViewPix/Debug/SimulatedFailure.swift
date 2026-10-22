//
//  SimulatedFailure.swift
//  DejaViewPix
//

#if DEBUG
import Foundation

/// Debug-only fault injection for the Messages API. When armed, it answers the next
/// requests itself, without touching the network, then lets requests through again. The
/// request (and its key header) is never read or stored.
nonisolated final class SimulatedFailure: URLProtocol {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case offline
        case badKey
        case rateLimitedOnce
        case overloadedTwice
        case overloadedAlways
        case roundCap

        var id: Self { self }

        var title: String {
            switch self {
            case .offline: "Offline"
            case .badKey: "Bad API key (401)"
            case .rateLimitedOnce: "Rate limited once (429)"
            case .overloadedTwice: "Overloaded twice, then OK (529)"
            case .overloadedAlways: "Overloaded on every attempt (529)"
            case .roundCap: "Endless tool calls (round cap)"
            }
        }

        /// Requests answered before real ones go through again. Three attempts per request
        /// (the retry policy), five requests per search (the round cap).
        var count: Int {
            switch self {
            case .offline, .overloadedAlways: 3
            case .badKey, .rateLimitedOnce: 1
            case .overloadedTwice: 2
            case .roundCap: 5
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode?
    nonisolated(unsafe) private static var remaining = 0

    /// A session that routes requests through this protocol first.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [SimulatedFailure.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }()

    /// Simulates `mode` for its `count` requests; nil turns simulation off.
    static func arm(_ mode: Mode?) {
        lock.withLock {
            self.mode = mode
            remaining = mode?.count ?? 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { mode != nil && remaining > 0 }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mode: Mode? = Self.lock.withLock {
            guard Self.remaining > 0 else { return nil }
            Self.remaining -= 1
            return Self.mode
        }

        switch mode {
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .badKey:
            respond(401, error: "authentication_error", message: "invalid x-api-key (simulated)")
        case .rateLimitedOnce:
            respond(429, error: "rate_limit_error", message: "Rate limited (simulated)", headers: ["retry-after": "3"])
        case .overloadedTwice, .overloadedAlways:
            respond(529, error: "overloaded_error", message: "Overloaded (simulated)")
        case .roundCap:
            // A valid reply that always asks for another tool call, so the loop never ends
            // on its own. list_albums is cheap and needs no input.
            respond(200, body: """
                {"id":"msg_sim","type":"message","role":"assistant","model":"simulated",
                 "content":[{"type":"tool_use","id":"toolu_sim_\(UUID().uuidString.prefix(8))","name":"list_albums","input":{}}],
                 "stop_reason":"tool_use","usage":{"input_tokens":0,"output_tokens":0}}
                """)
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, error: String, message: String, headers: [String: String] = [:]) {
        respond(status, body: #"{"type":"error","error":{"type":"\#(error)","message":"\#(message)"}}"#, headers: headers)
    }

    private func respond(_ status: Int, body: String, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["content-type": "application/json"]) { a, _ in a }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
