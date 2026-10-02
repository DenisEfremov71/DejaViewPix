//
//  ToolTypesTests.swift
//  AlbumAITests
//

import Foundation
import MapKit
import Photos
import Testing
@testable import AlbumAI

struct JSONValueTests {
    @Test func roundTripsNestedValues() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": false]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func keepsBooleansAndNumbersApart() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 0, "1"]"#.utf8))
        #expect(decoded == [true, 1, 0, "1"])
    }

    @Test func compactStringHasSortedKeys() {
        let value: JSONValue = ["b": 1, "a": "x/y", "c": 0.5]
        #expect(value.jsonString == #"{"a":"x/y","b":1,"c":0.5}"#)
    }
}

struct ToolBlockTests {
    @Test func decodesToolUseFromResponse() throws {
        let json = """
            {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5",
             "content":[{"type":"text","text":"Looking it up."},
                        {"type":"tool_use","id":"toolu_01","name":"geocode_place","input":{"place":"Whistler"}}],
             "stop_reason":"tool_use","usage":{"input_tokens":900,"output_tokens":60}}
            """
        let response = try JSONDecoder().decode(MessageResponse.self, from: Data(json.utf8))

        #expect(response.stopReason == "tool_use")
        #expect(response.content == [
            .text("Looking it up."),
            .toolUse(id: "toolu_01", name: "geocode_place", input: ["place": "Whistler"]),
        ])
        #expect(response.toolUses.map(\.id) == ["toolu_01"])
        #expect(response.text == "Looking it up.")
    }

    @Test func encodesToolResultWithErrorFlagOnlyWhenFailed() throws {
        let ok = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            ContentBlock.toolResult(toolUseID: "toolu_01", content: "{}")
        ))
        #expect(ok == ["type": "tool_result", "tool_use_id": "toolu_01", "content": "{}"])

        let failed = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            ContentBlock.toolResult(toolUseID: "toolu_01", content: "Boom", isError: true)
        ))
        #expect(failed == ["type": "tool_result", "tool_use_id": "toolu_01", "content": "Boom", "is_error": true])
    }

    @Test func toolUseRoundTrips() throws {
        let block = ContentBlock.toolUse(id: "toolu_01", name: "search_photos", input: ["limit": 5])
        #expect(try JSONDecoder().decode(ContentBlock.self, from: JSONEncoder().encode(block)) == block)
    }

    @Test func requestIncludesToolsOnlyWhenSet() throws {
        let tool = ToolDefinition(name: "list_albums", description: "Lists albums.", inputSchema: ["type": "object"])
        let withTools = MessageRequest(model: "m", maxTokens: 10, messages: [.user("Hi")], tools: [tool])
        let without = MessageRequest(model: "m", maxTokens: 10, messages: [.user("Hi")])

        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(withTools))
        #expect(encoded["tools"] == [["name": "list_albums", "description": "Lists albums.", "input_schema": ["type": "object"]]])

        let plain = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(without))
        #expect(plain["tools"] == nil)
    }
}

struct PhotoKitMappingTests {
    @Test func everythingButLocationGoesIntoThePredicate() throws {
        let query = PhotoQuery(
            from: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 86_400),
            mediaType: .photo,
            favoritesOnly: true,
            sortOrder: .oldestFirst
        )
        let options = PhotoLibrary.fetchOptions(for: query, fetchLimit: 31)
        let format = try #require(options.predicate?.predicateFormat)

        #expect(format.contains("creationDate >= "))
        #expect(format.contains("creationDate < "))
        #expect(format.contains("mediaType == 1"))
        #expect(format.contains("favorite == 1"))
        #expect(options.fetchLimit == 31)
        #expect(options.sortDescriptors?.first?.ascending == true)
    }

    @Test func classifiesGeocodedPlaces() {
        #expect(PlaceGeocoder.kind(name: "Whistler", category: nil, city: "Whistler", country: "Canada", hasStreetAddress: false) == .city)
        #expect(PlaceGeocoder.kind(name: "Canada", category: nil, city: nil, country: "Canada", hasStreetAddress: false) == .country)
        #expect(PlaceGeocoder.kind(name: "British Columbia", category: nil, city: nil, country: "Canada", hasStreetAddress: false) == .region)
        #expect(PlaceGeocoder.kind(name: "Gastown", category: nil, city: "Vancouver", country: "Canada", hasStreetAddress: false) == .neighborhood)
        #expect(PlaceGeocoder.kind(name: "Long Beach", category: .beach, city: "Tofino", country: "Canada", hasStreetAddress: true) == .beach)
        #expect(Place.Kind.city.radiusMeters > Place.Kind.beach.radiusMeters)
    }
}
