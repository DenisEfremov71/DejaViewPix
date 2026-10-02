//
//  ClaudeClient.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import Foundation

struct Message: Encodable {
    let role: String
    let content: String
}

struct MessageRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]

    private enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

struct ContentBlock: Decodable {
    let type: String
    let text: String?
}

struct Usage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct MessageResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage

    private enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }
}

struct APIErrorResponse: Decodable {
    let error: Detail

    struct Detail: Decodable {
        let type: String
        let message: String
    }
}

public enum ClaudeError: LocalizedError {
    case http(status: Int, type: String?, message: String?)
    case invalidResponse
    case noTextContent

    public var errorDescription: String? {
        switch self {
        case .http(let status, let type, let message):
            if let message {
                let typeLabel = type.map { ", \($0)" } ?? ""
                return
                    "Claude API error (HTTP \(status)\(typeLabel)): \(message)"
            }
            return "Claude API returned HTTP \(status) with no error details."

        case .invalidResponse:
            return "Unexpected response from the server (not an HTTP response)."

        case .noTextContent:
            return "Claude responded, but the reply contained no text."
        }
    }
}

public enum ClaudeModel: String, Sendable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case nonexisting = "claude-nope"
}

public struct ClaudeClient: Sendable {
    public var model: ClaudeModel
    public var maxTokens: Int
    public var session: URLSession

    /// Returns the API key. Called on every request, so the key is never stored in the client.
    private let apiKey: @Sendable () throws -> String

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    public init(
        model: ClaudeModel = .haiku,
        maxTokens: Int = 1024,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () throws -> String
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.session = session
        self.apiKey = apiKey
    }

    private func makeRequest(prompt: String) throws -> URLRequest {
        let apiKey = try apiKey()

        let body = MessageRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            messages: [Message(role: "user", content: prompt)]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(
            Self.apiVersion,
            forHTTPHeaderField: "anthropic-version"
        )
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        return request
    }

    public func send(_ prompt: String) async throws -> String {
        let request = try makeRequest(prompt: prompt)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        #if DEBUG
            if let requestID = httpResponse.value(
                forHTTPHeaderField: "request-id"
            ) {
                print("[Claude] request-id: \(requestID)")
            }
        #endif

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(
                APIErrorResponse.self,
                from: data
            )
            throw ClaudeError.http(
                status: httpResponse.statusCode,
                type: apiError?.error.type,
                message: apiError?.error.message
            )
        }

        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)

        #if DEBUG
            print(
                "[Claude] stop_reason: \(decoded.stopReason ?? "nil"), tokens in/out: \(decoded.usage.inputTokens)/\(decoded.usage.outputTokens)"
            )
        #endif

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")

        guard !text.isEmpty else {
            throw ClaudeError.noTextContent
        }

        if decoded.stopReason == "max_tokens" {
            return text + "\n\n(Reply truncated: reached the max_tokens limit.)"
        }

        return text
    }
}
