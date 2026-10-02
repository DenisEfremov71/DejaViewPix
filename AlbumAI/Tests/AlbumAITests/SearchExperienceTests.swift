//
//  SearchExperienceTests.swift
//  AlbumAITests
//

import Foundation
import Testing
@testable import AlbumAI

private let english = Locale(identifier: "en_US")

private let tofinoResult = ToolCallRecord(
    id: "toolu_1",
    name: "geocode_place",
    input: ["place": "Tofino, British Columbia"],
    output: ToolOutput(content: #"{"kind":"city","latitude":49.1529,"longitude":-125.9066,"name":"Tofino, BC, Canada","radius_meters":15000}"#)
)

// MARK: - Date ranges

struct DateRangeTextTests {
    @Test(arguments: [
        ("2025-07-01", "2025-07-31", "July 2025"),
        ("2025-07-01", "2025-08-31", "July–August 2025"),
        ("2025-12-01", "2026-02-28", "December 2025–February 2026"),
        ("2024-02-01", "2024-02-29", "February 2024"),
        ("2025-01-01", "2025-12-31", "2025"),
        ("2024-01-01", "2025-12-31", "2024–2025"),
        ("2026-01-14", "2026-01-14", "Jan 14, 2026"),
        ("2026-01-14", "2026-02-03", "Jan 14 – Feb 3, 2026"),
        ("2025-12-28", "2026-01-03", "Dec 28, 2025 – Jan 3, 2026"),
        ("2025-07-01", "2025-08-30", "Jul 1 – Aug 30, 2025"),
    ])
    func ranges(from: String, to: String, expected: String) {
        #expect(DateRangeText.describe(from: from, to: to, locale: english) == expected)
    }

    @Test func openEnded() {
        #expect(DateRangeText.describe(from: "2026-01-14", to: nil, locale: english) == "since Jan 14, 2026")
        #expect(DateRangeText.describe(from: nil, to: "2026-01-14", locale: english) == "until Jan 14, 2026")
        #expect(DateRangeText.describe(from: nil, to: nil, locale: english) == nil)
    }
}

// MARK: - Status lines

struct StatusLineTests {
    @Test func geocodeUsesTheShortPlaceName() {
        let start = ToolCallStart(name: "geocode_place", input: ["place": "Tofino, British Columbia"])
        #expect(start.statusLine(locale: english) == "Finding Tofino…")
    }

    @Test func searchNamesDatesAndTheGeocodedPlace() {
        let start = ToolCallStart(name: "search_photos", input: [
            "date_from": "2025-07-01", "date_to": "2025-08-31",
            "latitude": 49.1529, "longitude": -125.9066, "radius_meters": 15000,
        ], earlierCalls: [tofinoResult])
        #expect(start.statusLine(locale: english) == "Searching July–August 2025 near Tofino…")
    }

    @Test(arguments: [
        (JSONValue.object([:]), "Searching your whole library…"),
        (["media_type": "video", "favorites_only": true], "Searching favorite videos…"),
        (["media_type": "photo", "date_from": "2026-01-14", "date_to": "2026-01-14"], "Searching photos from Jan 14, 2026…"),
        (["album": "Trips"], "Searching in “Trips”…"),
        (["latitude": 1, "longitude": 2, "radius_meters": 300], "Searching near the place…"),
    ] as [(JSONValue, String)])
    func searchVariants(input: JSONValue, expected: String) {
        #expect(ToolCallStart(name: "search_photos", input: input).statusLine(locale: english) == expected)
    }

    @Test func otherTools() {
        #expect(ToolCallStart(name: "list_albums", input: [:]).statusLine() == "Checking your albums…")
        #expect(ToolCallStart(name: "present_results", input: [:]).statusLine() == "Putting your results together…")
    }

    @Test func loopReportsEachToolBeforeItRuns() async throws {
        let client = ScriptedClient([
            response(.toolUse(id: "toolu_1", name: "geocode_place", input: ["place": "Tofino, British Columbia"])),
            response(.toolUse(id: "toolu_2", name: "search_photos", input: [
                "latitude": 49.1529, "longitude": -125.9066, "radius_meters": 15000,
            ])),
            response(.toolUse(id: "toolu_3", name: "present_results", input: ["summary": "Nothing.", "photo_ids": []])),
        ])
        let tools = PhotoTools(
            library: FakeLibrary(),
            geocoder: FakeGeocoder(places: [
                "Tofino, British Columbia": Place(name: "Tofino, BC, Canada", latitude: 49.1529, longitude: -125.9066, kind: .city),
            ]),
            timeZone: .gmt
        )
        let recorder = StatusRecorder()

        _ = try await ToolLoop(client: client, tools: tools).run("tofino", system: "", onToolStart: { start in
            await recorder.add(start.statusLine(locale: english))
        })

        #expect(await recorder.lines == ["Finding Tofino…", "Searching near Tofino…", "Putting your results together…"])
    }
}

private actor StatusRecorder {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}

private func response(_ blocks: ContentBlock...) -> MessageResponse {
    MessageResponse(model: "claude-haiku-4-5", content: blocks, stopReason: "tool_use", usage: Usage(inputTokens: 1, outputTokens: 1))
}

// MARK: - Chips

struct FilterChipTests {
    private let tofino = GeoCircle(latitude: 49.1529, longitude: -125.9066, radiusMeters: 15_000)

    private var summer: AppliedFilters {
        AppliedFilters(dateFrom: "2025-07-01", dateTo: "2025-08-31", mediaType: "video", near: tofino, place: "Tofino, BC, Canada")
    }

    @Test func chipsInDisplayOrder() {
        #expect(summer.chips == [
            .dates(from: "2025-07-01", to: "2025-08-31"),
            .place(name: "Tofino, BC, Canada", circle: tofino),
            .mediaType("video"),
        ])
        #expect(summer.chips.map { $0.label(locale: english) } == ["July–August 2025", "Tofino · 15 km", "Videos"])
        #expect(AppliedFilters().chips.isEmpty)
        #expect(AppliedFilters(favoritesOnly: true, album: "Trips", sort: "oldest_first").chips == [.album("Trips"), .favorites, .oldestFirst])
    }

    @Test func radiusText() {
        #expect(FilterChip.radiusText(300) == "300 m")
        #expect(FilterChip.radiusText(1_500) == "1.5 km")
        #expect(FilterChip.radiusText(200_000) == "200 km")
    }

    @Test func removingAChipClearsOnlyThatFilter() {
        let edited = [summer].replacing(.dates(from: "2025-07-01", to: "2025-08-31"), with: nil)
        #expect(edited == [AppliedFilters(mediaType: "video", near: tofino, place: "Tofino, BC, Canada")])
    }

    @Test func editingAChipReplacesIt() {
        let wider = GeoCircle(latitude: tofino.latitude, longitude: tofino.longitude, radiusMeters: 50_000)
        let edited = summer.replacing(.place(name: "Tofino, BC, Canada", circle: tofino), with: .place(name: "Tofino, BC, Canada", circle: wider))
        #expect(edited.near == wider)
        #expect(edited.replacing(.mediaType("video"), with: .mediaType("photo")).mediaType == "photo")
    }

    @Test func aChipTheSearchDoesNotHaveChangesNothing() {
        #expect(summer.replacing(.favorites, with: nil) == summer)
        #expect(summer.replacing(.mediaType("photo"), with: nil) == summer)
    }

    @Test func chipsAcrossSearchesAreDistinctAndSearchesMerge() {
        let winter = AppliedFilters(dateFrom: "2025-12-01", dateTo: "2026-02-28", mediaType: "video")
        let searches = [summer, winter]
        #expect(searches.chips.filter { if case .mediaType = $0 { true } else { false } } == [.mediaType("video")])

        // Both searches lose their media type; neither becomes a duplicate of the other.
        #expect(searches.replacing(.mediaType("video"), with: nil).count == 2)

        // Two searches that differ only by dates collapse into one when dates are removed.
        let a = AppliedFilters(dateFrom: "2025-01-01", dateTo: "2025-01-31", mediaType: "video")
        let b = AppliedFilters(dateFrom: "2025-01-01", dateTo: "2025-01-31")
        #expect([a, b].replacing(.mediaType("video"), with: nil) == [b])
    }

    @Test func placeNameForPhotosInsideTheArea() {
        let searches = [summer]
        #expect(searches.placeName(latitude: 49.16, longitude: -125.90) == "Tofino")
        #expect(searches.placeName(latitude: 49.0, longitude: -123.0) == nil)
        #expect(searches.placeName(latitude: nil, longitude: nil) == nil)
    }
}

// MARK: - Local search

struct LocalSearchTests {
    private let vancouver = TimeZone(identifier: "America/Vancouver")!

    @Test func editedFiltersRunAgainstTheLibraryWithoutTheModel() async throws {
        let library = FakeLibrary(result: PhotoSearchResult(
            matches: [PhotoMatch(id: "A", creationDate: nil), PhotoMatch(id: "B", creationDate: nil)],
            hasMore: true
        ))
        let tools = PhotoTools(library: library, geocoder: FakeGeocoder(), timeZone: vancouver)
        let filters = AppliedFilters(dateFrom: "2025-07-01", dateTo: "2025-08-31", mediaType: "video", limit: 12)

        let result = try await tools.search([filters].replacing(.mediaType("video"), with: nil))

        #expect(result.matches.map(\.id) == ["A", "B"])
        #expect(result.hasMore)
        let query = try #require(await library.queries.first)
        #expect(query.mediaType == nil)
        #expect(query.limit == 12)
        #expect(query.from == (try Date("2025-07-01T07:00:00Z", strategy: .iso8601)))
        #expect(query.until == (try Date("2025-09-01T07:00:00Z", strategy: .iso8601)))
    }

    @Test func severalSearchesMergeWithoutDuplicates() async throws {
        let library = FakeLibrary(result: PhotoSearchResult(matches: [PhotoMatch(id: "A", creationDate: nil)], hasMore: false))
        let tools = PhotoTools(library: library, geocoder: FakeGeocoder(), timeZone: vancouver)

        let result = try await tools.search([AppliedFilters(mediaType: "photo"), AppliedFilters(mediaType: "video")])

        #expect(result.matches.map(\.id) == ["A"])
        #expect(await library.queries.count == 2)
    }

    @Test func noFiltersSearchesTheWholeLibrary() async throws {
        let library = FakeLibrary()
        let tools = PhotoTools(library: library, geocoder: FakeGeocoder(), timeZone: vancouver)

        _ = try await tools.search([])

        #expect(await library.queries == [PhotoQuery()])
    }
}
