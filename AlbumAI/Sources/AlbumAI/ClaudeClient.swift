//
//  ClaudeClient.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import Foundation

public enum ClaudeModel: String, Sendable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case nonexisting = "claude-nope"
}

/// A successful reply plus the metrics for the call.
public struct ClaudeReply: Sendable, Equatable {
    public var text: String
    public var stopReason: String?
    public var usage: Usage
    public var latency: Duration
    public var requestID: String?
}

/// Sends one Messages API request with a full conversation. `ClaudeClient` conforms;
/// tests swap in a scripted fake.
public protocol MessageSending: Sendable {
    func createMessage(
        system: String?,
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> MessageResponse
}

public actor ClaudeClient: MessageSending {
    public let model: ClaudeModel
    public let maxTokens: Int
    public let system: String?
    public let retryPolicy: RetryPolicy
    private let endpoint: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Returns the API key. Called on every request, so the key is never stored in the client.
    private let apiKey: @Sendable () throws -> String

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    public init(
        model: ClaudeModel = .haiku,
        maxTokens: Int = 8192,
        system: String? = nil,
        endpoint: URL = ClaudeClient.endpoint,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        apiKey: @escaping @Sendable () throws -> String
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.endpoint = endpoint
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.apiKey = apiKey
    }

    public func send(_ prompt: String) async throws -> ClaudeReply {
        let body = MessageRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            system: system,
            messages: [.user(prompt)]
        )
        let request = try Self.makeURLRequest(body: body, apiKey: apiKey(), endpoint: endpoint)

        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let latency = start.duration(to: clock.now)

        try Task.checkCancellation()
        return try Self.makeReply(data: data, response: response, latency: latency)
    }

    // MARK: - Conversations with tools

    /// Sends a whole conversation and returns the decoded reply, tool calls included.
    /// Retryable failures are retried with backoff, like `stream(_:)`.
    public nonisolated func createMessage(
        system: String?,
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> MessageResponse {
        let body = MessageRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            system: system,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )

        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await createMessageOnce(body)
            } catch {
                guard !Task.isCancelled,
                      attempt < retryPolicy.maxAttempts,
                      RetryPolicy.isRetryable(error)
                else { throw error }

                attempt += 1
                try await sleep(retryPolicy.delay(
                    beforeAttempt: attempt,
                    retryAfter: (error as? ClaudeError)?.retryAfter
                ))
            }
        }
    }

    private nonisolated func createMessageOnce(_ body: MessageRequest) async throws -> MessageResponse {
        let request = try Self.makeURLRequest(body: body, apiKey: apiKey(), endpoint: endpoint)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClaudeError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw Self.httpError(data: data, response: httpResponse)
            }
            return try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    // MARK: - Streaming

    /// Streams the reply to `prompt`. Retryable failures are retried with backoff, but only
    /// before the first event arrives; after that, errors end the stream. Cancelling the
    /// consuming task, or dropping the stream, cancels the network request.
    public nonisolated func stream(_ prompt: String) -> AsyncThrowingStream<StreamEvent, any Error> {
        let body = MessageRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            system: system,
            messages: [.user(prompt)],
            stream: true
        )
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, any Error>.makeStream()

        // Not isolated to any actor, so reading and decoding never run on the main actor.
        let task = Task {
            do {
                try await streamWithRetries(body, to: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }

        return stream
    }

    private nonisolated func streamWithRetries(
        _ body: MessageRequest,
        to continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            var started = false
            do {
                try await streamOnce(body, to: continuation, started: &started)
                return
            } catch {
                // Once events have been yielded, a retry would duplicate the text on screen.
                guard !started,
                      !Task.isCancelled,
                      attempt < retryPolicy.maxAttempts,
                      RetryPolicy.isRetryable(error)
                else { throw error }

                attempt += 1
                let delay = retryPolicy.delay(
                    beforeAttempt: attempt,
                    retryAfter: (error as? ClaudeError)?.retryAfter
                )
                continuation.yield(.retrying(
                    attempt: attempt,
                    maxAttempts: retryPolicy.maxAttempts,
                    delay: delay,
                    reason: error.localizedDescription
                ))
                try await sleep(delay)
            }
        }
    }

    private nonisolated func streamOnce(
        _ body: MessageRequest,
        to continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation,
        started: inout Bool
    ) async throws {
        let request = try Self.makeURLRequest(body: body, apiKey: apiKey(), endpoint: endpoint)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClaudeError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                throw Self.httpError(data: data, response: httpResponse)
            }

            var reader = EventStreamReader()
            for try await line in bytes.lines {
                if let event = try reader.consume(line: line) {
                    started = true
                    continuation.yield(event)
                }
            }
            if let event = try reader.finish() {
                continuation.yield(event)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    // MARK: - Request and response helpers

    static func makeURLRequest(
        body: MessageRequest,
        apiKey: String,
        endpoint: URL = ClaudeClient.endpoint
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func makeReply(data: Data, response: URLResponse, latency: Duration) throws -> ClaudeReply {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "request-id")

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw httpError(data: data, response: httpResponse)
        }

        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        let text = decoded.text

        guard !text.isEmpty else {
            throw ClaudeError.noTextContent(stopReason: decoded.stopReason)
        }

        return ClaudeReply(
            text: text,
            stopReason: decoded.stopReason,
            usage: decoded.usage,
            latency: latency,
            requestID: requestID
        )
    }
}

extension ClaudeClient {
    /// The typed error for a non-2xx response, built from the error body when it decodes.
    static func httpError(data: Data, response: HTTPURLResponse) -> ClaudeError {
        let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { Double($0) }
            .map { Duration.seconds($0) }
        return ClaudeError.http(
            status: response.statusCode,
            type: apiError?.error.type,
            message: apiError?.error.message,
            requestID: response.value(forHTTPHeaderField: "request-id"),
            retryAfter: retryAfter
        )
    }
}
