//
//  ToolLoopTests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

// MARK: - Fakes

/// Replies with canned responses in order and records every request.
actor ScriptedClient: MessageSending {
    struct SentRequest {
        var system: String?
        var messages: [Message]
        var tools: [ToolDefinition]
    }

    private var responses: [MessageResponse]
    private(set) var requests: [SentRequest] = []

    init(_ responses: [MessageResponse]) {
        self.responses = responses
    }

    func createMessage(system: String?, messages: [Message], tools: [ToolDefinition]) async throws -> MessageResponse {
        requests.append(SentRequest(system: system, messages: messages, tools: tools))
        precondition(!responses.isEmpty, "No scripted response left")
        return responses.removeFirst()
    }
}

/// Answers every request with the same response.
struct RepeatingClient: MessageSending {
    let response: MessageResponse
    let counter = Counter()

    func createMessage(system: String?, messages: [Message], tools: [ToolDefinition]) async throws -> MessageResponse {
        await counter.increment()
        return response
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

actor FakeLibrary: PhotoSearching {
    private let result: PhotoSearchResult
    private let albumList: [AlbumInfo]
    private let error: (any Error)?
    private(set) var queries: [PhotoQuery] = []

    init(result: PhotoSearchResult = .init(matches: [], hasMore: false), albums: [AlbumInfo] = [], error: (any Error)? = nil) {
        self.result = result
        self.albumList = albums
        self.error = error
    }

    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        queries.append(query)
        if let error { throw error }
        return result
    }

    func albums() async throws -> [AlbumInfo] {
        albumList
    }
}

struct FakeGeocoder: PlaceGeocoding {
    var places: [String: Place] = [:]

    func geocode(_ place: String) async throws -> Place {
        guard let match = places[place] else { throw ToolError.placeNotFound(place) }
        return match
    }
}

// MARK: - Helpers

private let vancouver = TimeZone(identifier: "America/Vancouver")!

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

private func reply(_ blocks: ContentBlock..., stop: String = "tool_use") -> MessageResponse {
    MessageResponse(content: blocks, stopReason: stop, usage: Usage(inputTokens: 100, outputTokens: 20))
}

private let whistler = Place(name: "Whistler, BC, Canada", latitude: 50.116_32, longitude: -122.957_36, kind: .city)

// MARK: - Loop

struct ToolLoopTests {
    @Test func whistlerLastWinterRoundTrip() async throws {
        let geocodeCall = ContentBlock.toolUse(
            id: "toolu_1", name: "geocode_place", input: ["place": "Whistler, British Columbia"]
        )
        let searchCall = ContentBlock.toolUse(id: "toolu_2", name: "search_photos", input: [
            "date_from": "2025-12-01",
            "date_to": "2026-02-28",
            "latitude": 50.1163,
            "longitude": -122.9574,
            "radius_meters": 15000,
        ])
        let client = ScriptedClient([
            reply(.text("Let me find Whistler first."), geocodeCall),
            reply(searchCall),
            reply(.text("I found 2 photos from Whistler last winter."), stop: "end_turn"),
        ])
        let library = FakeLibrary(result: PhotoSearchResult(matches: [
            PhotoMatch(id: "A/L0/001", creationDate: date("2026-01-14T18:30:00Z"), distanceMeters: 1_234),
            PhotoMatch(id: "B/L0/001", creationDate: date("2025-12-20T20:05:00Z"), isFavorite: true, distanceMeters: 4_480),
        ], hasMore: false))
        let tools = PhotoTools(
            library: library,
            geocoder: FakeGeocoder(places: ["Whistler, British Columbia": whistler]),
            timeZone: vancouver
        )
        let system = SearchPrompt.system(now: date("2026-10-02T17:00:00Z"), timeZone: vancouver)

        let result = try await ToolLoop(client: client, tools: tools).run("photos from Whistler last winter", system: system)

        #expect(result.finalText == "I found 2 photos from Whistler last winter.")
        #expect(result.photoIDs == ["A/L0/001", "B/L0/001"])
        #expect(result.rounds.map(\.toolCalls.count) == [1, 1, 0])
        #expect(result.usage == Usage(inputTokens: 300, outputTokens: 60))

        let requests = await client.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.system == system && $0.tools.count == 3 })

        // Second request: user, the assistant message unchanged, then the tool result.
        let second = requests[1].messages
        #expect(second.count == 3)
        #expect(second[0] == .user("photos from Whistler last winter"))
        #expect(second[1] == Message(role: .assistant, content: [.text("Let me find Whistler first."), geocodeCall]))
        #expect(second[2] == Message(role: .user, content: [.toolResult(
            toolUseID: "toolu_1",
            content: #"{"kind":"city","latitude":50.1163,"longitude":-122.9574,"name":"Whistler, BC, Canada","radius_meters":15000}"#
        )]))

        // Third request carries the search results, with dates in the user's time zone.
        let third = requests[2].messages
        #expect(third.count == 5)
        #expect(third[4] == Message(role: .user, content: [.toolResult(
            toolUseID: "toolu_2",
            content: #"{"more_available":false,"photos":[{"date":"2026-01-14 10:30","id":"A/L0/001","km":1.2},{"date":"2025-12-20 12:05","favorite":true,"id":"B/L0/001","km":4.5}],"returned":2}"#
        )]))

        // Whole days in Vancouver time; date_to is inclusive.
        let query = try #require(await library.queries.first)
        #expect(query.from == date("2025-12-01T08:00:00Z"))
        #expect(query.until == date("2026-03-01T08:00:00Z"))
        #expect(query.near == GeoCircle(latitude: 50.1163, longitude: -122.9574, radiusMeters: 15_000))
        #expect(query.limit == 30)
    }

    @Test func failingToolGoesBackAsErrorAndLoopContinues() async throws {
        let client = ScriptedClient([
            reply(.toolUse(id: "toolu_1", name: "geocode_place", input: ["place": "Atlantis"])),
            reply(.text("I couldn't find that place."), stop: "end_turn"),
        ])
        let tools = PhotoTools(library: FakeLibrary(), geocoder: FakeGeocoder(), timeZone: vancouver)

        let result = try await ToolLoop(client: client, tools: tools).run("Atlantis", system: "")

        #expect(result.finalText == "I couldn't find that place.")
        let sent = await client.requests[1].messages[2]
        #expect(sent == Message(role: .user, content: [.toolResult(
            toolUseID: "toolu_1",
            content: ToolError.placeNotFound("Atlantis").localizedDescription,
            isError: true
        )]))
    }

    @Test func libraryErrorAndUnknownToolAndBadInputAreErrors() async throws {
        let client = ScriptedClient([
            reply(
                .toolUse(id: "toolu_1", name: "search_photos", input: ["album": "Nope"]),
                .toolUse(id: "toolu_2", name: "delete_photos", input: [:]),
                .toolUse(id: "toolu_3", name: "search_photos", input: ["date_from": "last winter"])
            ),
            reply(.text("Done."), stop: "end_turn"),
        ])
        let library = FakeLibrary(error: ToolError.albumNotFound("Nope"))
        let tools = PhotoTools(library: library, geocoder: FakeGeocoder(), timeZone: vancouver)

        let result = try await ToolLoop(client: client, tools: tools).run("q", system: "")

        // One result per call, same order, all in one user message.
        let calls = try #require(result.rounds.first?.toolCalls)
        #expect(calls.map(\.id) == ["toolu_1", "toolu_2", "toolu_3"])
        #expect(calls.allSatisfy { $0.output.isError })
        #expect(calls[0].output.content == ToolError.albumNotFound("Nope").localizedDescription)
        #expect(calls[1].output.content == #"There is no tool named "delete_photos"."#)
        #expect(calls[2].output.content.contains("YYYY-MM-DD"))
        #expect(result.photoIDs.isEmpty)

        let sent = await client.requests[1].messages[2].content
        #expect(sent.count == 3)
    }

    @Test func stopsAfterFiveRounds() async throws {
        let client = RepeatingClient(response: reply(.toolUse(id: "toolu_1", name: "list_albums", input: [:])))
        let tools = PhotoTools(library: FakeLibrary(), geocoder: FakeGeocoder(), timeZone: vancouver)

        await #expect(throws: ToolLoopError.roundLimitReached(5)) {
            try await ToolLoop(client: client, tools: tools).run("q", system: "")
        }
        #expect(await client.counter.value == 5)
    }

    @Test func unexpectedStopReasonThrows() async throws {
        let client = ScriptedClient([reply(.text("Partial"), stop: "max_tokens")])
        let tools = PhotoTools(library: FakeLibrary(), geocoder: FakeGeocoder(), timeZone: vancouver)

        await #expect(throws: ToolLoopError.unexpectedStop("max_tokens")) {
            try await ToolLoop(client: client, tools: tools).run("q", system: "")
        }
    }

    @Test func cancellationInsideToolIsNotSentToClaude() async throws {
        let client = ScriptedClient([
            reply(.toolUse(id: "toolu_1", name: "search_photos", input: [:])),
            reply(.text("Done."), stop: "end_turn"),
        ])
        let tools = PhotoTools(library: FakeLibrary(error: CancellationError()), geocoder: FakeGeocoder(), timeZone: vancouver)

        await #expect(throws: CancellationError.self) {
            try await ToolLoop(client: client, tools: tools).run("q", system: "")
        }
        #expect(await client.requests.count == 1)
    }

    @Test func listAlbumsIsCompact() async throws {
        let library = FakeLibrary(albums: [
            AlbumInfo(title: "Ski trip", count: 42),
            AlbumInfo(title: "Selfies", count: 3, isSmartAlbum: true),
        ])
        let tools = PhotoTools(library: library, geocoder: FakeGeocoder(), timeZone: vancouver)

        let output = try await tools.execute(name: "list_albums", input: [:])

        #expect(output.content == #"{"albums":[{"count":42,"title":"Ski trip"},{"count":3,"smart":true,"title":"Selfies"}]}"#)
    }
}

// MARK: - search_photos input

struct SearchInputTests {
    private let tools = PhotoTools(library: FakeLibrary(), geocoder: FakeGeocoder(), timeZone: vancouver)

    private func query(_ input: JSONValue) throws -> PhotoQuery {
        try tools.query(from: input.decode())
    }

    @Test func emptyInputSearchesEverything() throws {
        #expect(try query([:]) == PhotoQuery())
    }

    @Test func mapsAllFilters() throws {
        let query = try query([
            "media_type": "video", "favorites_only": true, "album": " Ski trip ",
            "limit": 500, "sort": "oldest_first",
        ])
        #expect(query.mediaType == .video)
        #expect(query.favoritesOnly)
        #expect(query.album == "Ski trip")
        #expect(query.limit == PhotoTools.maxLimit)
        #expect(query.sortOrder == .oldestFirst)
    }

    @Test(arguments: [
        ["date_from": "2026-03-01", "date_to": "2026-02-01"] as JSONValue,
        ["date_from": "2026-02-30"],
        ["date_to": "yesterday"],
        ["latitude": 50.0, "longitude": -122.0],
        ["latitude": 95.0, "longitude": 0.0, "radius_meters": 100],
        ["latitude": 50.0, "longitude": -122.0, "radius_meters": 0],
        ["media_type": "gif"],
        ["sort": "random"],
    ])
    func rejectsInvalidInput(_ input: JSONValue) {
        #expect(throws: ToolError.self) { try query(input) }
    }

    @Test func wrongTypeIsAReadableError() async {
        await #expect(throws: ToolError.invalidInput("limit has the wrong type.")) {
            try await tools.execute(name: "search_photos", input: ["limit": "ten"])
        }
        await #expect(throws: ToolError.invalidInput("place is required.")) {
            try await tools.execute(name: "geocode_place", input: [:])
        }
    }
}

// MARK: - Prompt and definitions

struct SearchPromptTests {
    @Test func todayLineUsesInjectedDateAndTimeZone() {
        // 03:00 UTC on Oct 3 is still Oct 2 in Vancouver.
        let line = SearchPrompt.todayLine(now: date("2026-10-03T03:00:00Z"), timeZone: vancouver)
        #expect(line == "Today is 2026-10-02 (Friday), time zone America/Vancouver.")

        let system = SearchPrompt.system(now: date("2026-10-03T03:00:00Z"), timeZone: vancouver)
        #expect(system.contains(line))
    }

    @Test func toolDefinitionsEncodeAsJSONSchema() throws {
        let tools = PhotoTools(library: FakeLibrary(), geocoder: FakeGeocoder(), timeZone: vancouver)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tools.definitions))

        guard case .array(let definitions) = json else {
            Issue.record("Expected an array")
            return
        }
        #expect(definitions.map { $0["name"] } == ["search_photos", "geocode_place", "list_albums"])
        #expect(definitions.allSatisfy { $0["input_schema"]?["type"] == "object" })
        #expect(definitions[1]["input_schema"]?["required"] == ["place"])
    }
}
