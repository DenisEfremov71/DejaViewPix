//
//  MessagesAPI.swift
//  AlbumAI
//

import Foundation

// Codable models for the Claude Messages API (POST /v1/messages).

public struct MessageRequest: Encodable, Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]

    public init(model: String, maxTokens: Int, system: String? = nil, messages: [Message]) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

public struct Message: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(text)])
    }
}

/// A content block. Types this client doesn't know yet decode as `.unknown`,
/// so new block types from the API never break decoding.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case unknown(type: String)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)

        case .unknown(let type):
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Cannot encode a content block of unknown type \"\(type)\"."
                )
            )
        }
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct MessageResponse: Decodable, Sendable, Equatable {
    public var content: [ContentBlock]
    public var stopReason: String?
    public var usage: Usage

    private enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }

    /// The text blocks joined together; other block types are skipped.
    public var text: String {
        content
            .compactMap { block in
                if case .text(let text) = block { text } else { nil }
            }
            .joined(separator: "\n")
    }
}

/// Error body: {"type":"error","error":{"type":"…","message":"…"}}
struct APIErrorResponse: Decodable {
    let error: Detail

    struct Detail: Decodable {
        let type: String
        let message: String
    }
}
