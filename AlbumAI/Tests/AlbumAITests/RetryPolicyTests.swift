//
//  RetryPolicyTests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

struct RetryPolicyTests {
    private func httpError(_ status: Int) -> ClaudeError {
        .http(status: status, type: nil, message: nil, requestID: nil, retryAfter: nil)
    }

    @Test(arguments: [429, 500, 503, 529])
    func serverAndRateLimitErrorsAreRetryable(status: Int) {
        #expect(RetryPolicy.isRetryable(httpError(status)))
    }

    @Test(arguments: [400, 401, 403, 404, 413])
    func clientErrorsAreNotRetryable(status: Int) {
        #expect(!RetryPolicy.isRetryable(httpError(status)))
    }

    @Test func classifiesOtherErrors() {
        #expect(RetryPolicy.isRetryable(URLError(.timedOut)))
        #expect(RetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        #expect(!RetryPolicy.isRetryable(URLError(.badURL)))
        #expect(!RetryPolicy.isRetryable(CancellationError()))
        #expect(!RetryPolicy.isRetryable(ClaudeError.stream(type: "overloaded_error", message: "Overloaded")))
        #expect(!RetryPolicy.isRetryable(ClaudeError.streamInterrupted))
    }

    @Test func delaysGrowExponentially() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), jitter: { 1 })

        let delays = (2...5).map { policy.delay(beforeAttempt: $0, retryAfter: nil) }

        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func jitterScalesBetweenHalfAndFull() {
        let low = RetryPolicy(baseDelay: .seconds(2), jitter: { 0 })
        #expect(low.delay(beforeAttempt: 2, retryAfter: nil) == .seconds(1))
    }

    @Test func delayIsCapped() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .seconds(1), maxDelay: .seconds(5), jitter: { 1 })
        #expect(policy.delay(beforeAttempt: 9, retryAfter: nil) == .seconds(5))
    }

    @Test func retryAfterWinsButIsCapped() {
        let policy = RetryPolicy(maxDelay: .seconds(20), jitter: { 1 })
        #expect(policy.delay(beforeAttempt: 2, retryAfter: .seconds(7)) == .seconds(7))
        #expect(policy.delay(beforeAttempt: 2, retryAfter: .seconds(600)) == .seconds(20))
    }
}
