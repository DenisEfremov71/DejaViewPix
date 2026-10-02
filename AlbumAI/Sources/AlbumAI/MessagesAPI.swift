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
    /// Tools Claude may call. Omitted from the body when nil.
    public var tools: [ToolDefinition]?
    /// Sent only when true; the API defaults to a single JSON response.
    public var stream: Bool?

    public init(
        model: String,
        maxTokens: Int,
        system: String? = nil,
        messages: [Message],
        tools: [ToolDefinition]? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream
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
    /// Claude asks the client to run a tool.
    case toolUse(id: String, name: String, input: JSONValue)
    /// The client's answer to a `toolUse` block, sent back in a user message.
    case toolResult(toolUseID: String, content: String, isError: Bool = false)
    case unknown(type: String)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? "",
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
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

        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)

        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            if isError {
                try container.encode(true, forKey: .isError)
            }

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

/// A tool Claude may call: its name, a description (which is a prompt), and a JSON Schema for its input.
public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// When true, the API guarantees `tool_use` inputs match the schema. Omitted when nil.
    public var strict: Bool?

    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, strict
        case inputSchema = "input_schema"
    }
}

public struct Usage: Codable, Sendable, Equatable {
    /// Input tokens not read from or written to the prompt cache.
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        // The cache fields are absent or null when caching isn't used.
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }

    public static let zero = Usage(inputTokens: 0, outputTokens: 0)

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

public struct MessageResponse: Decodable, Sendable, Equatable {
    /// The model that answered, e.g. "claude-haiku-4-5-20251001".
    public var model: String?
    public var content: [ContentBlock]
    public var stopReason: String?
    public var usage: Usage

    public init(model: String? = nil, content: [ContentBlock], stopReason: String?, usage: Usage) {
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case model, content, usage
        case stopReason = "stop_reason"
    }

    /// The `tool_use` blocks, in order.
    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let input) = block { (id, name, input) } else { nil }
        }
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
