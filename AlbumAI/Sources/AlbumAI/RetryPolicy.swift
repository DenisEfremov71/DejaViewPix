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

/// A retry about to happen: which attempt comes next, after how long, and why.
public struct RetryNotice: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        case overloaded
        case rateLimited
        case serverError
        case network

        init(_ error: any Error) {
            switch error {
            case ClaudeError.http(429, _, _, _, _): self = .rateLimited
            case ClaudeError.http(529, _, _, _, _): self = .overloaded
            case ClaudeError.http(_, "overloaded_error", _, _, _): self = .overloaded
            case is ClaudeError: self = .serverError
            default: self = .network
            }
        }
    }

    /// The attempt about to be made: 2 for the first retry.
    public var attempt: Int
    public var maxAttempts: Int
    public var delay: Duration
    public var cause: Cause

    public init(attempt: Int, maxAttempts: Int, delay: Duration, cause: Cause) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.cause = cause
    }

    /// "Claude is busy. Retrying in 2 s (attempt 2 of 3)…"
    public var statusLine: String {
        let seconds = max(1, Int((delay / .seconds(1)).rounded(.up)))
        let reason = switch cause {
        case .overloaded: "Claude is busy."
        case .rateLimited: "Too many requests."
        case .serverError: "Claude had a problem."
        case .network: "The connection failed."
        }
        return "\(reason) Retrying in \(seconds) s (attempt \(attempt) of \(maxAttempts))…"
    }
}
