//
//  ClaudeStreamTests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

/// Serves canned replies. Each test registers its replies under a unique host,
/// so tests running in parallel don't share state.
final class MockURLProtocol: URLProtocol {
    enum Reply {
        case http(status: Int, headers: [String: String] = [:], body: String)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// Registers replies, served in order, and returns the endpoint that serves them.
    static func register(_ replies: [Reply]) -> URL {
        let host = "mock-\(UUID().uuidString.lowercased()).test"
        lock.withLock { self.replies[host] = replies }
        return URL(string: "https://\(host)/v1/messages")!
    }

    static func requestCount(for endpoint: URL) -> Int {
        lock.withLock { counts[endpoint.host!, default: 0] }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let reply: Reply? = Self.lock.withLock {
            Self.counts[url.host!, default: 0] += 1
            guard var queue = Self.replies[url.host!], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            Self.replies[url.host!] = queue
            return next
        }

        switch reply {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {}
}

/// Records the backoff sleeps instead of waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []
    private var _cancelled = false

    var delays: [Duration] { lock.withLock { _delays } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func instant(_ delay: Duration) async throws {
        lock.withLock { _delays.append(delay) }
    }

    /// Waits for an hour, unless cancelled.
    func forever(_ delay: Duration) async throws {
        lock.withLock { _delays.append(delay) }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
    }
}

struct ClaudeStreamTests {
    private static let overloaded = MockURLProtocol.Reply.http(
        status: 529,
        body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
    )
    private static let ok = MockURLProtocol.Reply.http(
        status: 200,
        headers: ["content-type": "text/event-stream"],
        body: RecordedStream.hello
    )

    private func makeClient(
        _ endpoint: URL,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) -> ClaudeClient {
        ClaudeClient(
            endpoint: endpoint,
            session: MockURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1), jitter: { 1 }),
            sleep: sleep,
            apiKey: { "sk-test" }
        )
    }

    private func collect(_ stream: AsyncThrowingStream<StreamEvent, any Error>) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func streamsTextFromRecordedResponse() async throws {
        let endpoint = MockURLProtocol.register([Self.ok])
        let client = makeClient(endpoint, sleep: SleepRecorder().instant)

        let events = try await collect(client.stream("Hi"))

        #expect(events == RecordedStream.helloEvents)
    }

    @Test func retriesOverloadWithGrowingDelays() async throws {
        let endpoint = MockURLProtocol.register([Self.overloaded, Self.overloaded, Self.ok])
        let recorder = SleepRecorder()
        let client = makeClient(endpoint, sleep: recorder.instant)

        let events = try await collect(client.stream("Hi"))

        let retries = events.compactMap { event -> Int? in
            if case .retrying(let attempt, 3, _, _) = event { attempt } else { nil }
        }
        #expect(retries == [2, 3])
        #expect(recorder.delays == [.seconds(1), .seconds(2)])
        #expect(Array(events.dropFirst(2)) == RecordedStream.helloEvents)
        #expect(MockURLProtocol.requestCount(for: endpoint) == 3)
    }

    @Test func usesRetryAfterHeader() async throws {
        let rateLimited = MockURLProtocol.Reply.http(status: 429, headers: ["retry-after": "4"], body: "")
        let endpoint = MockURLProtocol.register([rateLimited, Self.ok])
        let recorder = SleepRecorder()

        _ = try await collect(makeClient(endpoint, sleep: recorder.instant).stream("Hi"))

        #expect(recorder.delays == [.seconds(4)])
    }

    @Test func retriesTransientNetworkErrors() async throws {
        let endpoint = MockURLProtocol.register([.failure(URLError(.networkConnectionLost)), Self.ok])

        let events = try await collect(makeClient(endpoint, sleep: SleepRecorder().instant).stream("Hi"))

        #expect(events.last == .messageStop)
        #expect(MockURLProtocol.requestCount(for: endpoint) == 2)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let endpoint = MockURLProtocol.register([Self.overloaded, Self.overloaded, Self.overloaded, Self.ok])
        let client = makeClient(endpoint, sleep: SleepRecorder().instant)

        await #expect(
            throws: ClaudeError.http(
                status: 529,
                type: "overloaded_error",
                message: "Overloaded",
                requestID: nil,
                retryAfter: nil
            )
        ) {
            try await collect(client.stream("Hi"))
        }
        #expect(MockURLProtocol.requestCount(for: endpoint) == 3)
    }

    @Test func doesNotRetryAuthErrors() async throws {
        let unauthorized = MockURLProtocol.Reply.http(
            status: 401,
            body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        )
        let endpoint = MockURLProtocol.register([unauthorized, Self.ok])
        let client = makeClient(endpoint, sleep: SleepRecorder().instant)

        await #expect(throws: ClaudeError.self) {
            try await collect(client.stream("Hi"))
        }
        #expect(MockURLProtocol.requestCount(for: endpoint) == 1)
    }

    @Test func doesNotRetryAfterStreamStarted() async throws {
        let midStreamError = MockURLProtocol.Reply.http(
            status: 200,
            body: """
                event: message_start
                data: {"type":"message_start","message":{"id":"msg_01","usage":{"input_tokens":12,"output_tokens":1}}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

                event: error
                data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

                """
        )
        let endpoint = MockURLProtocol.register([midStreamError, Self.ok])
        let recorder = SleepRecorder()
        let client = makeClient(endpoint, sleep: recorder.instant)

        var received: [StreamEvent] = []
        await #expect(throws: ClaudeError.stream(type: "overloaded_error", message: "Overloaded")) {
            for try await event in client.stream("Hi") {
                received.append(event)
            }
        }
        #expect(received.count == 2)
        #expect(recorder.delays.isEmpty)
        #expect(MockURLProtocol.requestCount(for: endpoint) == 1)
    }

    @Test func cancelStopsBackoffWait() async throws {
        let endpoint = MockURLProtocol.register([Self.overloaded, Self.ok])
        let recorder = SleepRecorder()
        let client = makeClient(endpoint, sleep: recorder.forever)

        let consumer = Task {
            for try await _ in client.stream("Hi") {}
            try Task.checkCancellation()
        }
        try await waitUntil { !recorder.delays.isEmpty }

        let clock = ContinuousClock()
        let start = clock.now
        consumer.cancel()
        await #expect(throws: CancellationError.self) {
            try await consumer.value
        }
        try await waitUntil { recorder.cancelled }

        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(MockURLProtocol.requestCount(for: endpoint) == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
