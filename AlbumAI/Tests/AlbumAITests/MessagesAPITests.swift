//
//  MessagesAPITests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

struct RequestEncodingTests {
    private func encodeToJSON(_ request: MessageRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesSnakeCaseKeysAndContentBlocks() throws {
        let request = MessageRequest(
            model: "claude-haiku-4-5",
            maxTokens: 256,
            messages: [.user("Hi")]
        )

        let json = try encodeToJSON(request)

        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["maxTokens"] == nil)
        #expect(json["system"] == nil)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")

        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "Hi")
    }

    @Test func includesSystemPromptWhenSet() throws {
        let request = MessageRequest(
            model: "claude-haiku-4-5",
            maxTokens: 256,
            system: "You are terse.",
            messages: [.user("Hi")]
        )

        let json = try encodeToJSON(request)

        #expect(json["system"] as? String == "You are terse.")
    }

    @Test func unknownBlockRoundTripsUnchanged() throws {
        let json = #"{"signature":"EqQBCkYI","thinking":"The user wants photos.","type":"thinking"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))

        guard case .unknown(let type, _) = block else {
            Issue.record("Expected an unknown block, got \(block)")
            return
        }
        #expect(type == "thinking")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(block), as: UTF8.self) == json)
    }

    @Test func urlRequestHasMethodAndHeaders() throws {
        let body = MessageRequest(model: "claude-haiku-4-5", maxTokens: 16, messages: [.user("Hi")])

        let request = try ClaudeClient.makeURLRequest(body: body, apiKey: "sk-test")

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let sentBody = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(DecodableRequest.self, from: sentBody).max_tokens == 16)
    }

    private struct DecodableRequest: Decodable {
        let max_tokens: Int
    }
}

struct ResponseDecodingTests {
    private static let successJSON = """
        {
          "id": "msg_01",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5",
          "content": [
            {"type": "thinking", "thinking": "", "signature": "abc"},
            {"type": "text", "text": "Hello"},
            {"type": "text", "text": "there"}
          ],
          "stop_reason": "end_turn",
          "stop_sequence": null,
          "usage": {"input_tokens": 12, "output_tokens": 3, "cache_read_input_tokens": 0}
        }
        """

    private func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: ClaudeClient.endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test func decodesKnownAndUnknownBlocks() throws {
        let response = try JSONDecoder().decode(MessageResponse.self, from: Data(Self.successJSON.utf8))

        #expect(response.content == [.unknown(type: "thinking", raw: ["type": "thinking", "thinking": "", "signature": "abc"]), .text("Hello"), .text("there")])
        #expect(response.stopReason == "end_turn")
        #expect(response.usage == Usage(inputTokens: 12, outputTokens: 3))
        #expect(response.text == "Hello\nthere")
    }

    @Test func successfulResponseBecomesReplyWithMetrics() throws {
        let reply = try ClaudeClient.makeReply(
            data: Data(Self.successJSON.utf8),
            response: httpResponse(status: 200, headers: ["request-id": "req_123"]),
            latency: .milliseconds(420)
        )

        #expect(reply.text == "Hello\nthere")
        #expect(reply.stopReason == "end_turn")
        #expect(reply.usage == Usage(inputTokens: 12, outputTokens: 3))
        #expect(reply.latency == .milliseconds(420))
        #expect(reply.requestID == "req_123")
    }

    @Test func errorBodyBecomesTypedError() {
        let body = """
            {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
            """

        #expect(
            throws: ClaudeError.http(
                status: 401,
                type: "authentication_error",
                message: "invalid x-api-key",
                requestID: "req_456",
                retryAfter: .seconds(30)
            )
        ) {
            try ClaudeClient.makeReply(
                data: Data(body.utf8),
                response: httpResponse(status: 401, headers: ["request-id": "req_456", "retry-after": "30"]),
                latency: .zero
            )
        }
    }

    @Test func unreadableErrorBodyKeepsStatus() {
        #expect(
            throws: ClaudeError.http(status: 529, type: nil, message: nil, requestID: nil, retryAfter: nil)
        ) {
            try ClaudeClient.makeReply(
                data: Data("<html>Overloaded</html>".utf8),
                response: httpResponse(status: 529),
                latency: .zero
            )
        }
    }

    @Test func replyWithoutTextThrows() {
        let body = """
            {"content": [], "stop_reason": "refusal", "usage": {"input_tokens": 5, "output_tokens": 0}}
            """

        #expect(throws: ClaudeError.noTextContent(stopReason: "refusal")) {
            try ClaudeClient.makeReply(
                data: Data(body.utf8),
                response: httpResponse(status: 200),
                latency: .zero
            )
        }
    }

    @Test func errorMessageIsReadable() {
        let error = ClaudeError.http(
            status: 401,
            type: "authentication_error",
            message: "invalid x-api-key",
            requestID: "req_456",
            retryAfter: nil
        )

        #expect(
            error.localizedDescription
                == "Claude API error (HTTP 401, authentication_error): invalid x-api-key\nRequest ID: req_456"
        )
    }
}
