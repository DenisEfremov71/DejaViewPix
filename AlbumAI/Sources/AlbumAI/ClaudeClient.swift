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

public actor ClaudeClient {
    public let model: ClaudeModel
    public let maxTokens: Int
    public let system: String?
    private let session: URLSession

    /// Returns the API key. Called on every request, so the key is never stored in the client.
    private let apiKey: @Sendable () throws -> String

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    public init(
        model: ClaudeModel = .haiku,
        maxTokens: Int = 1024,
        system: String? = nil,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () throws -> String
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.session = session
        self.apiKey = apiKey
    }

    public func send(_ prompt: String) async throws -> ClaudeReply {
        let body = MessageRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            system: system,
            messages: [.user(prompt)]
        )
        let request = try Self.makeURLRequest(body: body, apiKey: apiKey())

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

    static func makeURLRequest(body: MessageRequest, apiKey: String) throws -> URLRequest {
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
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                .flatMap { Double($0) }
                .map { Duration.seconds($0) }
            throw ClaudeError.http(
                status: httpResponse.statusCode,
                type: apiError?.error.type,
                message: apiError?.error.message,
                requestID: requestID,
                retryAfter: retryAfter
            )
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
