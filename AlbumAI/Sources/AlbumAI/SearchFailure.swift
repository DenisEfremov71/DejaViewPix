//
//  SearchFailure.swift
//  AlbumAI
//

import Foundation

/// A failed search, explained for the user: what happened and what to do about it. The
/// technical description stays available for the details view and the log.
public struct SearchFailure: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Running the same search again may work.
        case tryAgain
        /// The API key needs attention.
        case checkAPIKey
        /// Describing the photos differently is more likely to work than repeating.
        case rephrase
    }

    public var title: String
    public var message: String
    public var action: Action
    /// The underlying error, e.g. "Claude API error (HTTP 529, overloaded_error): Overloaded".
    public var detail: String

    public init(title: String, message: String, action: Action, detail: String) {
        self.title = title
        self.message = message
        self.action = action
        self.detail = detail
    }

    public init(_ error: any Error) {
        let detail = error.localizedDescription
        switch error {
        case APIKeyStoreError.missingKey:
            self.init(
                title: "No API Key",
                message: "Add your Claude API key in the API Key tab, then search again.",
                action: .checkAPIKey, detail: detail
            )

        case ClaudeError.http(401, _, _, _, _), ClaudeError.http(403, _, _, _, _):
            self.init(
                title: "API Key Not Accepted",
                message: "Claude rejected the saved API key. Check it in the API Key tab.",
                action: .checkAPIKey, detail: detail
            )

        case ClaudeError.http(429, _, _, _, _):
            self.init(
                title: "Too Many Requests",
                message: "Claude is limiting requests for this key. Wait a minute, then try again.",
                action: .tryAgain, detail: detail
            )

        case ClaudeError.http(529, _, _, _, _), ClaudeError.http(_, "overloaded_error", _, _, _):
            self.init(
                title: "Claude Is Overloaded",
                message: "The service is very busy right now, and three attempts failed. Try again in a minute.",
                action: .tryAgain, detail: detail
            )

        case ClaudeError.http(let status, _, _, _, _) where status >= 500:
            self.init(
                title: "Claude Had a Problem",
                message: "The service returned an error. Try again shortly.",
                action: .tryAgain, detail: detail
            )

        case let error as URLError where Self.offlineCodes.contains(error.code):
            self.init(
                title: "You're Offline",
                message: "Searching needs an internet connection. Connect, then try again.",
                action: .tryAgain, detail: detail
            )

        case let error as URLError where error.code == .timedOut:
            self.init(
                title: "No Response",
                message: "Claude didn't answer in time. Check your connection and try again.",
                action: .tryAgain, detail: detail
            )

        case is SearchTimeout:
            self.init(
                title: "Search Took Too Long",
                message: "The search was stopped after \(Int(SearchTimeout.limit / .seconds(1))) seconds. Try again, or describe the photos more simply.",
                action: .tryAgain, detail: detail
            )

        case ToolLoopError.roundLimitReached:
            self.init(
                title: "Search Didn't Settle",
                message: "Claude kept searching without reaching an answer. Try a more specific description, such as a place and a month.",
                action: .rephrase, detail: detail
            )

        case ToolLoopError.invalidAnswer, ToolLoopError.noAnswer:
            self.init(
                title: "No Clear Answer",
                message: "Claude couldn't turn this into a photo search. Try describing the photos: when, where, or what kind.",
                action: .rephrase, detail: detail
            )

        case ToolLoopError.unexpectedStop("refusal"):
            self.init(
                title: "Request Declined",
                message: "Claude declined this request. Try describing the photos you want to find.",
                action: .rephrase, detail: detail
            )

        default:
            self.init(
                title: "Search Didn't Finish",
                message: detail,
                action: .tryAgain, detail: detail
            )
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
        .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]
}

/// A whole search ran past `SearchTimeout.limit`.
public struct SearchTimeout: LocalizedError, Sendable, Equatable {
    /// Typical searches take 3–9 s; three retries with backoff add up to about 30 s.
    public static let limit: Duration = .seconds(60)

    public init() {}

    public var errorDescription: String? {
        "The search didn't finish within \(Int(Self.limit / .seconds(1))) seconds."
    }
}

/// Runs `operation`, and cancels it with `SearchTimeout` if it takes longer than `limit`.
/// Cancelling the caller cancels the operation too.
public func withSearchTimeout<T: Sendable>(
    _ limit: Duration = SearchTimeout.limit,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(limit)
            throw SearchTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
