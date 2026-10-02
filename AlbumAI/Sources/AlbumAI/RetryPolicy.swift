//
//  RetryPolicy.swift
//  AlbumAI
//

import Foundation

/// Decides which failures to retry and how long to wait between attempts.
public struct RetryPolicy: Sendable {
    /// Total attempts, including the first one.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Returns a value in 0..<1. Injected so tests get predictable delays.
    public var jitter: @Sendable () -> Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(20),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Rate limits, server errors (including 529 overloaded) and transient network errors.
    public static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case ClaudeError.http(let status, _, _, _, _):
            return status == 429 || (500...599).contains(status)
        case let error as URLError:
            return [
                .timedOut,
                .networkConnectionLost,
                .notConnectedToInternet,
                .cannotConnectToHost,
                .dnsLookupFailed,
            ].contains(error.code)
        default:
            return false
        }
    }

    /// The wait before attempt `attempt` (2 for the first retry). Uses the server's
    /// `retry-after` when present; otherwise exponential backoff scaled by 50–100% jitter.
    public func delay(beforeAttempt attempt: Int, retryAfter: Duration?) -> Duration {
        if let retryAfter {
            return min(retryAfter, maxDelay)
        }
        let exponential = baseDelay * (1 << max(attempt - 2, 0))
        let jittered = exponential * (0.5 + 0.5 * jitter())
        return min(jittered, maxDelay)
    }
}

extension ClaudeError {
    var retryAfter: Duration? {
        if case .http(_, _, _, _, let retryAfter) = self { retryAfter } else { nil }
    }
}
