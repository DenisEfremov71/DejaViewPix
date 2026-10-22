//
//  HardeningTests.swift
//  AlbumAITests
//
//  Day 9: every failure path ends in a clear message, and nothing waits forever.
//

import Foundation
import Testing
@testable import AlbumAI

private actor NoticeRecorder {
    private(set) var notices: [RetryNotice] = []
    func add(_ notice: RetryNotice) { notices.append(notice) }
}

private func http(_ status: Int, _ type: String, headers: [String: String] = [:]) -> MockURLProtocol.Reply {
    .http(status: status, headers: headers, body: #"{"type":"error","error":{"type":"\#(type)","message":"simulated"}}"#)
}

private let okReply = MockURLProtocol.Reply.http(status: 200, body: """
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001",
     "content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn",
     "usage":{"input_tokens":5,"output_tokens":1}}
    """)

private func makeClient(_ endpoint: URL) -> ClaudeClient {
    ClaudeClient(
        endpoint: endpoint,
        session: MockURLProtocol.makeSession(),
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1), jitter: { 1 }),
        sleep: { _ in },
        apiKey: { "sk-test" }
    )
}

struct RetryNoticeTests {
    @Test func createMessageReportsEachRetry() async throws {
        let endpoint = MockURLProtocol.register([http(529, "overloaded_error"), http(429, "rate_limit_error", headers: ["retry-after": "7"]), okReply])
        let recorder = NoticeRecorder()

        let response = try await ClaudeClient.$retryObserver.withValue({ await recorder.add($0) }) {
            try await makeClient(endpoint).createMessage(system: nil, messages: [.user("Hi")], tools: [])
        }

        #expect(response.text == "Hi")
        #expect(await recorder.notices == [
            RetryNotice(attempt: 2, maxAttempts: 3, delay: .seconds(1), cause: .overloaded),
            RetryNotice(attempt: 3, maxAttempts: 3, delay: .seconds(7), cause: .rateLimited),
        ])
    }

    @Test func noObserverMeansNoNotices() async throws {
        let endpoint = MockURLProtocol.register([http(529, "overloaded_error"), okReply])
        _ = try await makeClient(endpoint).createMessage(system: nil, messages: [.user("Hi")], tools: [])
        #expect(MockURLProtocol.requestCount(for: endpoint) == 2)
    }

    @Test func statusLines() {
        #expect(RetryNotice(attempt: 2, maxAttempts: 3, delay: .milliseconds(1_400), cause: .overloaded).statusLine
            == "Claude is busy. Retrying in 2 s (attempt 2 of 3)…")
        #expect(RetryNotice(attempt: 3, maxAttempts: 3, delay: .seconds(7), cause: .rateLimited).statusLine
            == "Too many requests. Retrying in 7 s (attempt 3 of 3)…")
        #expect(RetryNotice(attempt: 2, maxAttempts: 3, delay: .zero, cause: .network).statusLine
            == "The connection failed. Retrying in 1 s (attempt 2 of 3)…")
    }

    @Test func causes() {
        #expect(RetryNotice.Cause(ClaudeError.http(status: 529, type: nil, message: nil, requestID: nil, retryAfter: nil)) == .overloaded)
        #expect(RetryNotice.Cause(ClaudeError.http(status: 500, type: "overloaded_error", message: nil, requestID: nil, retryAfter: nil)) == .overloaded)
        #expect(RetryNotice.Cause(ClaudeError.http(status: 503, type: "api_error", message: nil, requestID: nil, retryAfter: nil)) == .serverError)
        #expect(RetryNotice.Cause(URLError(.notConnectedToInternet)) == .network)
    }
}

struct SearchFailureTests {
    private func status(_ code: Int, _ type: String? = nil) -> ClaudeError {
        .http(status: code, type: type, message: "x", requestID: "req_1", retryAfter: nil)
    }

    @Test func eachFailureGetsATitleAndAnAction() {
        let cases: [(any Error, String, SearchFailure.Action)] = [
            (APIKeyStoreError.missingKey, "No API Key", .checkAPIKey),
            (status(401, "authentication_error"), "API Key Not Accepted", .checkAPIKey),
            (status(429, "rate_limit_error"), "Too Many Requests", .tryAgain),
            (status(529, "overloaded_error"), "Claude Is Overloaded", .tryAgain),
            (status(500, "api_error"), "Claude Had a Problem", .tryAgain),
            (URLError(.notConnectedToInternet), "You're Offline", .tryAgain),
            (URLError(.timedOut), "No Response", .tryAgain),
            (SearchTimeout(), "Search Took Too Long", .tryAgain),
            (ToolLoopError.roundLimitReached(5), "Search Didn't Settle", .rephrase),
            (ToolLoopError.noAnswer, "No Clear Answer", .rephrase),
            (ToolLoopError.invalidAnswer("bad ids"), "No Clear Answer", .rephrase),
            (ToolLoopError.unexpectedStop("refusal"), "Request Declined", .rephrase),
            (status(400, "invalid_request_error"), "Search Didn't Finish", .tryAgain),
        ]
        for (error, title, action) in cases {
            let failure = SearchFailure(error)
            #expect(failure.title == title, "\(error)")
            #expect(failure.action == action, "\(error)")
            #expect(failure.detail == error.localizedDescription)
        }
    }

    @Test func technicalDetailKeepsTheRequestID() {
        #expect(SearchFailure(status(529, "overloaded_error")).detail.contains("Request ID: req_1"))
    }
}

struct SearchTimeoutTests {
    @Test func slowOperationTimesOut() async {
        await #expect(throws: SearchTimeout.self) {
            try await withSearchTimeout(.seconds(60), sleep: { _ in }) {
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }
    }

    @Test func fastOperationReturnsItsValue() async throws {
        let value = try await withSearchTimeout(.seconds(60)) { 42 }
        #expect(value == 42)
    }

    @Test func operationErrorsPassThrough() async {
        await #expect(throws: ToolLoopError.noAnswer) {
            try await withSearchTimeout(.seconds(60)) { () async throws -> Int in throw ToolLoopError.noAnswer }
        }
    }

    @Test func cancellingTheCallerCancelsTheOperation() async {
        let task = Task {
            try await withSearchTimeout(.seconds(3600)) {
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
