//
//  StreamingParserTests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

/// A text stream as the Messages API sends it, including a `ping`.
enum RecordedStream {
    static let hello = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type": "ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}


        """

    static let helloEvents: [StreamEvent] = [
        .messageStart(id: "msg_01", usage: Usage(inputTokens: 12, outputTokens: 1)),
        .contentBlockStart(index: 0, type: "text"),
        .textDelta(index: 0, text: "Hello"),
        .textDelta(index: 0, text: " there"),
        .contentBlockStop(index: 0),
        .messageDelta(stopReason: "end_turn", outputTokens: 3),
        .messageStop,
    ]
}

struct StreamingParserTests {
    /// Feeds `text` to a reader line by line, the way the client does.
    private func events(from text: String, dropBlankLines: Bool = false) throws -> [StreamEvent] {
        var reader = EventStreamReader()
        var events: [StreamEvent] = []
        // NSString splitting works on UTF-16, so "\r\n" leaves a trailing "\r" like the network does.
        for line in text.components(separatedBy: "\n") where !(dropBlankLines && line.isEmpty) {
            if let event = try reader.consume(line: line) {
                events.append(event)
            }
        }
        if let event = try reader.finish() {
            events.append(event)
        }
        return events
    }

    @Test func decodesRecordedStream() throws {
        #expect(try events(from: RecordedStream.hello) == RecordedStream.helloEvents)
    }

    @Test func worksWithoutBlankLines() throws {
        // URLSession.AsyncBytes.lines drops empty lines.
        #expect(try events(from: RecordedStream.hello, dropBlankLines: true) == RecordedStream.helloEvents)
    }

    @Test func handlesCRLFLineEndings() throws {
        let crlf = RecordedStream.hello.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try events(from: crlf) == RecordedStream.helloEvents)
    }

    @Test func joinsMultiLineData() throws {
        var parser = SSEParser()
        #expect(parser.consume(line: "event: custom") == nil)
        #expect(parser.consume(line: "data: first") == nil)
        #expect(parser.consume(line: "data:second") == nil)
        #expect(parser.consume(line: ": a comment") == nil)
        #expect(parser.consume(line: "") == SSEMessage(event: "custom", data: "first\nsecond"))
        #expect(parser.finish() == nil)
    }

    @Test func decodesJSONSplitAcrossDataLines() throws {
        let text = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,
            data: "delta":{"type":"text_delta","text":"Hi"}}

            event: message_stop
            data: {"type":"message_stop"}
            """
        #expect(try events(from: text) == [.textDelta(index: 0, text: "Hi"), .messageStop])
    }

    @Test func decodesToolArgumentDeltas() throws {
        let text = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\": \\"be"}}

            event: message_stop
            data: {"type":"message_stop"}
            """
        #expect(try events(from: text) == [.inputJSONDelta(index: 1, partialJSON: #"{"query": "be"#), .messageStop])
    }

    @Test func skipsUnknownEventsAndDeltaTypes() throws {
        let text = """
            event: brand_new_event
            data: {"type":"brand_new_event","whatever":true}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}

            event: ping
            data: {"type":"ping"}

            event: message_stop
            data: {"type":"message_stop"}
            """
        #expect(try events(from: text) == [.messageStop])
    }

    @Test func errorEventThrows() {
        let text = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_01","usage":{"input_tokens":12,"output_tokens":1}}}

            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
            """
        #expect(throws: ClaudeError.stream(type: "overloaded_error", message: "Overloaded")) {
            try events(from: text)
        }
    }

    @Test func streamCutOffMidwayThrows() {
        let cutOff = RecordedStream.hello.components(separatedBy: "event: content_block_stop")[0]
        #expect(throws: ClaudeError.streamInterrupted) {
            try events(from: cutOff)
        }
    }
}
