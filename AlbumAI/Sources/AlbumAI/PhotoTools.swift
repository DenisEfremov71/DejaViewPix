//
//  PhotoTools.swift
//  AlbumAI
//

import Foundation

/// A set of tools the loop can offer to Claude and run.
public protocol ToolExecuting: Sendable {
    var definitions: [ToolDefinition] { get }
    /// Runs one tool call. Any error thrown (except cancellation) goes back to Claude as a
    /// `tool_result` with `is_error: true`.
    func execute(name: String, input: JSONValue) async throws -> ToolOutput
}

public struct ToolOutput: Sendable, Equatable {
    /// The text sent back to Claude: compact JSON, or an error message.
    public var content: String
    public var isError: Bool
    /// Photo IDs this call returned, so the app can show them without parsing `content`.
    public var photoIDs: [String]

    public init(content: String, isError: Bool = false, photoIDs: [String] = []) {
        self.content = content
        self.isError = isError
        self.photoIDs = photoIDs
    }
}

public enum ToolError: LocalizedError, Sendable, Equatable {
    case unknownTool(String)
    case invalidInput(String)
    case albumNotFound(String)
    case placeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "There is no tool named \"\(name)\"."
        case .invalidInput(let message):
            "Invalid input: \(message)"
        case .albumNotFound(let title):
            "No album is titled \"\(title)\". Call list_albums to see the exact titles."
        case .placeNotFound(let place):
            "Could not find a place called \"\(place)\". Try a more specific name, such as \"town, region, country\"."
        }
    }
}

/// The three photo tools: `search_photos`, `geocode_place` and `list_albums`.
public struct PhotoTools: ToolExecuting {
    public static let maxLimit = 100

    private let library: any PhotoSearching
    private let geocoder: any PlaceGeocoding
    /// Dates in tool inputs and outputs are in this time zone.
    private let timeZone: TimeZone

    public init(library: any PhotoSearching, geocoder: any PlaceGeocoding, timeZone: TimeZone) {
        self.library = library
        self.geocoder = geocoder
        self.timeZone = timeZone
    }

    public func execute(name: String, input: JSONValue) async throws -> ToolOutput {
        switch name {
        case "search_photos": try await searchPhotos(Self.decode(input))
        case "geocode_place": try await geocodePlace(Self.decode(input))
        case "list_albums": try await listAlbums()
        default: throw ToolError.unknownTool(name)
        }
    }

    // MARK: - search_photos

    struct SearchPhotosInput: Decodable {
        var date_from: String?
        var date_to: String?
        var media_type: String?
        var favorites_only: Bool?
        var album: String?
        var latitude: Double?
        var longitude: Double?
        var radius_meters: Double?
        var limit: Int?
        var sort: String?
    }

    func query(from input: SearchPhotosInput) throws -> PhotoQuery {
        var query = PhotoQuery()

        let calendar = calendar
        if let dateFrom = input.date_from {
            query.from = try parseDay(dateFrom, field: "date_from")
        }
        if let dateTo = input.date_to {
            // Inclusive: everything before the start of the next day.
            let day = try parseDay(dateTo, field: "date_to")
            query.until = calendar.date(byAdding: .day, value: 1, to: day)
        }
        if let from = query.from, let until = query.until, from >= until {
            throw ToolError.invalidInput("date_from must be on or before date_to.")
        }

        switch input.media_type {
        case nil, "any": query.mediaType = nil
        case "photo": query.mediaType = .photo
        case "video": query.mediaType = .video
        case let other?: throw ToolError.invalidInput("media_type must be photo, video or any, not \"\(other)\".")
        }

        query.favoritesOnly = input.favorites_only ?? false

        if let album = input.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            query.album = album
        }

        switch (input.latitude, input.longitude, input.radius_meters) {
        case (nil, nil, nil):
            break
        case let (latitude?, longitude?, radius?):
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw ToolError.invalidInput("latitude must be within ±90 and longitude within ±180.")
            }
            guard radius > 0 else {
                throw ToolError.invalidInput("radius_meters must be greater than 0.")
            }
            query.near = GeoCircle(latitude: latitude, longitude: longitude, radiusMeters: radius)
        default:
            throw ToolError.invalidInput("latitude, longitude and radius_meters must be given together.")
        }

        query.limit = min(max(input.limit ?? 30, 1), Self.maxLimit)

        switch input.sort {
        case nil, "newest_first": query.sortOrder = .newestFirst
        case "oldest_first": query.sortOrder = .oldestFirst
        case let other?: throw ToolError.invalidInput("sort must be newest_first or oldest_first, not \"\(other)\".")
        }

        return query
    }

    private func searchPhotos(_ input: SearchPhotosInput) async throws -> ToolOutput {
        let result = try await library.search(query(from: input))

        let dateFormat = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone,
            calendar: calendar
        )
        let photos: [JSONValue] = result.matches.map { match in
            var photo: [String: JSONValue] = ["id": .string(match.id)]
            if let date = match.creationDate {
                photo["date"] = .string(date.formatted(dateFormat))
            }
            if let distance = match.distanceMeters {
                photo["km"] = .number((distance / 100).rounded() / 10)
            }
            if match.isVideo {
                photo["video"] = true
            }
            if match.isFavorite {
                photo["favorite"] = true
            }
            return .object(photo)
        }
        let content: JSONValue = [
            "photos": .array(photos),
            "returned": .number(Double(photos.count)),
            "more_available": .bool(result.hasMore),
        ]
        return ToolOutput(content: content.jsonString, photoIDs: result.matches.map(\.id))
    }

    // MARK: - geocode_place

    struct GeocodePlaceInput: Decodable {
        var place: String
    }

    private func geocodePlace(_ input: GeocodePlaceInput) async throws -> ToolOutput {
        let place = try await geocoder.geocode(input.place)
        let content: JSONValue = [
            "name": .string(place.name),
            "latitude": .number(Self.round(place.latitude, places: 4)),
            "longitude": .number(Self.round(place.longitude, places: 4)),
            "radius_meters": .number(place.radiusMeters),
            "kind": .string(place.kind.rawValue),
        ]
        return ToolOutput(content: content.jsonString)
    }

    // MARK: - list_albums

    private func listAlbums() async throws -> ToolOutput {
        let albums: [JSONValue] = try await library.albums().map { album in
            var entry: [String: JSONValue] = [
                "title": .string(album.title),
                "count": .number(Double(album.count)),
            ]
            if album.isSmartAlbum {
                entry["smart"] = true
            }
            return .object(entry)
        }
        return ToolOutput(content: JSONValue.object(["albums": .array(albums)]).jsonString)
    }

    // MARK: - Helpers

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Midnight at the start of a YYYY-MM-DD day, in the user's time zone.
    private func parseDay(_ text: String, field: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.day, from: date) == parts[2]
        else {
            throw ToolError.invalidInput("\(field) must be a date in YYYY-MM-DD form, not \"\(text)\".")
        }
        return date
    }

    private static func decode<T: Decodable>(_ input: JSONValue) throws -> T {
        do {
            return try input.decode(as: T.self)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ToolError.invalidInput("\(key.stringValue) is required.")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ToolError.invalidInput("\(field) has the wrong type.")
        } catch {
            throw ToolError.invalidInput("the input must be a JSON object.")
        }
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

// MARK: - Tool definitions

extension PhotoTools {
    public var definitions: [ToolDefinition] {
        [Self.searchPhotosDefinition, Self.geocodePlaceDefinition, Self.listAlbumsDefinition]
    }

    static let searchPhotosDefinition = ToolDefinition(
        name: "search_photos",
        description: """
            Searches the user's photo library and returns matching photos, newest first by default. \
            Each result has an id, the capture date and time in the user's time zone ("date"), \
            "km" (distance from the search center, only for location searches), and "video" or \
            "favorite" flags when true. All filters are optional and combine with AND. \
            Dates are whole days in the user's time zone, and both ends are inclusive. \
            For a place, call geocode_place first and pass its latitude, longitude and \
            radius_meters; photos without a location are left out of location searches. \
            For an album, pass its exact title from list_albums. \
            If "more_available" is true, there were more matches than the limit.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "date_from": [
                    "type": "string",
                    "description": "Earliest capture day, inclusive, as YYYY-MM-DD.",
                ],
                "date_to": [
                    "type": "string",
                    "description": "Latest capture day, inclusive, as YYYY-MM-DD.",
                ],
                "media_type": [
                    "type": "string",
                    "enum": ["photo", "video", "any"],
                    "description": "Defaults to any.",
                ],
                "favorites_only": [
                    "type": "boolean",
                    "description": "Only photos the user marked as favorites.",
                ],
                "album": [
                    "type": "string",
                    "description": "Exact album title from list_albums. Omit to search the whole library.",
                ],
                "latitude": [
                    "type": "number",
                    "description": "Center of the search area, from geocode_place.",
                ],
                "longitude": [
                    "type": "number",
                    "description": "Center of the search area, from geocode_place.",
                ],
                "radius_meters": [
                    "type": "number",
                    "description": "Radius of the search area. Use geocode_place's radius_meters unless the user asks for something tighter or wider.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": .number(Double(maxLimit)),
                    "description": "Maximum number of photos to return. Defaults to 30.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["newest_first", "oldest_first"],
                    "description": "Defaults to newest_first. Use oldest_first for \"my first photo of…\".",
                ],
            ],
            "additionalProperties": false,
        ]
    )

    static let geocodePlaceDefinition = ToolDefinition(
        name: "geocode_place",
        description: """
            Looks up a place name and returns its coordinates, a search radius sized to the \
            kind of place (a beach gets about 1.5 km, a city 15 km, a country 1000 km), and the \
            resolved name. Call it before search_photos whenever the user names a place. \
            Include the region or country when the name is ambiguous, e.g. \
            "Whistler, British Columbia" or "Paris, France". Check the resolved name: if it \
            is not the place the user meant, call again with a more specific name.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "place": [
                    "type": "string",
                    "description": "The place to look up, e.g. \"Whistler, British Columbia\".",
                ],
            ],
            "required": ["place"],
            "additionalProperties": false,
        ]
    )

    static let listAlbumsDefinition = ToolDefinition(
        name: "list_albums",
        description: """
            Lists the user's albums with their photo counts. Albums marked "smart" are kept by \
            Photos itself (such as Selfies or Screenshots). Call it when the user mentions an \
            album, or a kind of photo a smart album covers, to get the exact title for \
            search_photos.
            """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ]
    )
}
