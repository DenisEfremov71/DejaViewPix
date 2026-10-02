//
//  ServerSentEvents.swift
//  AlbumAI
//

import Foundation

/// One server-sent event: an optional `event:` name and its `data:` lines joined with "\n".
struct SSEMessage: Sendable, Equatable {
    var event: String?
    var data: String
}

/// Turns lines of a `text/event-stream` body into events.
///
/// An event normally ends at a blank line. `URLSession.AsyncBytes.lines` drops blank lines,
/// so a new `event:` line also ends the pending event, and `finish()` flushes the last one.
/// The Messages API always starts each event with an `event:` line, so this framing is safe.
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func consume(line rawLine: String) -> SSEMessage? {
        var line = Substring(rawLine)
        if line.unicodeScalars.last == "\r" {
            line = Substring(line.unicodeScalars.dropLast())
        }

        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil  // comment
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") {
                value = value.dropFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            let pending = dispatch()
            event = String(value)
            return pending
        case "data":
            dataLines.append(String(value))
        default:
            break  // id, retry and unknown fields aren't used by the Messages API
        }
        return nil
    }

    mutating func finish() -> SSEMessage? {
        dispatch()
    }

    private mutating func dispatch() -> SSEMessage? {
        defer {
            event = nil
            dataLines = []
        }
        // Per the SSE spec, an event without data is not dispatched.
        guard !dataLines.isEmpty else { return nil }
        return SSEMessage(event: event, data: dataLines.joined(separator: "\n"))
    }
}

/// An event from a streaming Messages API response.
public enum StreamEvent: Sendable, Equatable {
    /// Carries the input token usage.
    case messageStart(id: String, usage: Usage)
    case contentBlockStart(index: Int, type: String)
    case textDelta(index: Int, text: String)
    /// A piece of a tool call's JSON arguments.
    case inputJSONDelta(index: Int, partialJSON: String)
    case contentBlockStop(index: Int)
    /// Carries the stop reason and the output token count so far.
    case messageDelta(stopReason: String?, outputTokens: Int)
    case messageStop
    /// Sent by the client, not the API: a retryable failure happened before the stream started,
    /// and attempt `attempt` of `maxAttempts` begins after `delay`.
    case retrying(attempt: Int, maxAttempts: Int, delay: Duration, reason: String)
}

extension StreamEvent {
    /// Decodes one SSE message. Returns nil for `ping`, unknown events and unknown delta types,
    /// so new additions to the API don't break the stream. Throws for an `error` event.
    static func decode(_ message: SSEMessage) throws -> StreamEvent? {
        let data = Data(message.data.utf8)
        let decoder = JSONDecoder()
        let name = try message.event ?? decoder.decode(TypeOnly.self, from: data).type

        switch name {
        case "message_start":
            let payload = try decoder.decode(MessageStart.self, from: data)
            return .messageStart(id: payload.message.id, usage: payload.message.usage)

        case "content_block_start":
            let payload = try decoder.decode(ContentBlockStart.self, from: data)
            return .contentBlockStart(index: payload.index, type: payload.contentBlock.type)

        case "content_block_delta":
            let payload = try decoder.decode(ContentBlockDelta.self, from: data)
            switch payload.delta.type {
            case "text_delta":
                return .textDelta(index: payload.index, text: payload.delta.text ?? "")
            case "input_json_delta":
                return .inputJSONDelta(index: payload.index, partialJSON: payload.delta.partialJSON ?? "")
            default:
                return nil
            }

        case "content_block_stop":
            let payload = try decoder.decode(IndexOnly.self, from: data)
            return .contentBlockStop(index: payload.index)

        case "message_delta":
            let payload = try decoder.decode(MessageDelta.self, from: data)
            return .messageDelta(stopReason: payload.delta.stopReason, outputTokens: payload.usage.outputTokens)

        case "message_stop":
            return .messageStop

        case "error":
            let payload = try decoder.decode(APIErrorResponse.self, from: data)
            throw ClaudeError.stream(type: payload.error.type, message: payload.error.message)

        default:
            return nil  // ping, or an event type this client doesn't know yet
        }
    }

    private struct TypeOnly: Decodable {
        let type: String
    }

    private struct IndexOnly: Decodable {
        let index: Int
    }

    private struct MessageStart: Decodable {
        let message: Body

        struct Body: Decodable {
            let id: String
            let usage: Usage
        }
    }

    private struct ContentBlockStart: Decodable {
        let index: Int
        let contentBlock: TypeOnly

        private enum CodingKeys: String, CodingKey {
            case index
            case contentBlock = "content_block"
        }
    }

    private struct ContentBlockDelta: Decodable {
        let index: Int
        let delta: Delta

        struct Delta: Decodable {
            let type: String
            let text: String?
            let partialJSON: String?

            private enum CodingKeys: String, CodingKey {
                case type, text
                case partialJSON = "partial_json"
            }
        }
    }

    private struct MessageDelta: Decodable {
        let delta: Delta
        let usage: OutputUsage

        struct Delta: Decodable {
            let stopReason: String?

            private enum CodingKeys: String, CodingKey {
                case stopReason = "stop_reason"
            }
        }

        struct OutputUsage: Decodable {
            let outputTokens: Int

            private enum CodingKeys: String, CodingKey {
                case outputTokens = "output_tokens"
            }
        }
    }
}

/// Reads the lines of one streaming response and returns the events in it.
struct EventStreamReader {
    private var parser = SSEParser()
    private(set) var sawMessageStop = false

    mutating func consume(line: String) throws -> StreamEvent? {
        guard let message = parser.consume(line: line) else { return nil }
        return try decode(message)
    }

    /// Call when the bytes end. Throws `streamInterrupted` if `message_stop` never arrived.
    mutating func finish() throws -> StreamEvent? {
        let event = try parser.finish().flatMap { try decode($0) }
        guard sawMessageStop else {
            throw ClaudeError.streamInterrupted
        }
        return event
    }

    private mutating func decode(_ message: SSEMessage) throws -> StreamEvent? {
        let event = try StreamEvent.decode(message)
        if event == .messageStop {
            sawMessageStop = true
        }
        return event
    }
}
