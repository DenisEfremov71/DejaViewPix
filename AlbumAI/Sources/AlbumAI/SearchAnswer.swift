//
//  SearchAnswer.swift
//  AlbumAI
//

import Foundation

/// The validated final answer to a search.
public struct SearchAnswer: Sendable, Equatable {
    /// One or two sentences for the user, written by the model.
    public var summary: String
    /// Photos to show, best match first. Every ID came from a `search_photos` result.
    public var photoIDs: [String]
    /// The filters of the searches that produced these photos. Rebuilt from the tool calls
    /// that actually ran, never taken from the model's own account of what it did.
    public var filters: [AppliedFilters]

    public init(summary: String, photoIDs: [String], filters: [AppliedFilters]) {
        self.summary = summary
        self.photoIDs = photoIDs
        self.filters = filters
    }
}

/// The filters of one `search_photos` call, with defaults filled in.
public struct AppliedFilters: Sendable, Equatable {
    public var dateFrom: String?
    public var dateTo: String?
    /// "photo" or "video"; nil means both.
    public var mediaType: String?
    public var favoritesOnly: Bool
    public var album: String?
    public var near: GeoCircle?
    /// The geocoded name for `near`, when the circle came from a `geocode_place` result.
    public var place: String?
    public var sort: String
    public var limit: Int

    public init(
        dateFrom: String? = nil,
        dateTo: String? = nil,
        mediaType: String? = nil,
        favoritesOnly: Bool = false,
        album: String? = nil,
        near: GeoCircle? = nil,
        place: String? = nil,
        sort: String = "newest_first",
        limit: Int = 30
    ) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.mediaType = mediaType
        self.favoritesOnly = favoritesOnly
        self.album = album
        self.near = near
        self.place = place
        self.sort = sort
        self.limit = limit
    }

    /// E.g. "2025-12-01 to 2026-02-28 · within 15 km of Whistler, BC, Canada · photos".
    public var label: String {
        var parts: [String] = []
        switch (dateFrom, dateTo) {
        case let (from?, to?): parts.append(from == to ? "on \(from)" : "\(from) to \(to)")
        case let (from?, nil): parts.append("since \(from)")
        case let (nil, to?): parts.append("until \(to)")
        case (nil, nil): break
        }
        if let near {
            let km = (near.radiusMeters / 1000).formatted(.number.precision(.significantDigits(1...3)))
            let center = place ?? String(format: "%.4f, %.4f", near.latitude, near.longitude)
            parts.append("within \(km) km of \(center)")
        }
        if let album {
            parts.append("album \"\(album)\"")
        }
        if let mediaType {
            parts.append(mediaType == "video" ? "videos" : "photos")
        }
        if favoritesOnly {
            parts.append("favorites")
        }
        if sort == "oldest_first" {
            parts.append("oldest first")
        }
        return parts.isEmpty ? "whole library" : parts.joined(separator: " · ")
    }
}

// MARK: - present_results

extension SearchAnswer {
    public static let toolName = "present_results"

    /// Strict, so the API guarantees the input matches the schema. Our own checks only need
    /// to cover what a schema can't express.
    public static let toolDefinition = ToolDefinition(
        name: toolName,
        description: """
            Delivers your final answer to the app. Call it exactly once, on its own, after \
            your searches are done; nothing reaches the user until you do. \
            photo_ids: the IDs to show, best match first, copied exactly from search_photos \
            results. Leave out photos that don't fit the request, and pass an empty list if \
            nothing matched. \
            summary: one or two short sentences for the user saying what you found, e.g. \
            "3 photos from Whistler between December 2025 and February 2026." \
            If the app answers with an error, fix the problem it names and call \
            present_results again.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "photo_ids": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["summary", "photo_ids"],
            "additionalProperties": false,
        ],
        strict: true
    )

    struct PresentResultsInput: Decodable {
        var summary: String
        var photo_ids: [String]
    }

    /// Decodes and checks a `present_results` call against the tool calls that ran before it.
    /// Throws `ToolError.invalidInput` with a message the model can act on.
    static func validated(input: JSONValue, calls: [ToolCallRecord]) throws -> SearchAnswer {
        let decoded: PresentResultsInput
        do {
            decoded = try input.decode()
        } catch {
            throw ToolError.invalidInput("present_results needs a summary string and a photo_ids array of strings.")
        }

        let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw ToolError.invalidInput("summary is empty. Describe what you found in a sentence or two.")
        }

        var seen = Set<String>()
        let photoIDs = decoded.photo_ids.filter { seen.insert($0).inserted }

        // The model must not invent IDs: each one has to come from a search that succeeded.
        let searches = calls.filter { $0.name == "search_photos" && !$0.output.isError }
        let returned = Set(searches.flatMap(\.output.photoIDs))
        let unknown = photoIDs.filter { !returned.contains($0) }
        guard unknown.isEmpty else {
            let list = unknown.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
            let more = unknown.count > 5 ? " and \(unknown.count - 5) more" : ""
            throw ToolError.invalidInput(
                "These photo_ids were not returned by any search_photos call: \(list)\(more). "
                    + "Use only IDs copied from search_photos results."
            )
        }

        // Filters of the searches that contributed photos; with no photos, every search counts.
        let contributing = photoIDs.isEmpty
            ? searches
            : searches.filter { !Set($0.output.photoIDs).isDisjoint(with: photoIDs) }
        let filters = contributing.compactMap { appliedFilters(of: $0, geocodes: calls) }

        return SearchAnswer(summary: summary, photoIDs: photoIDs, filters: filters)
    }

    static func appliedFilters(of search: ToolCallRecord, geocodes calls: [ToolCallRecord]) -> AppliedFilters? {
        guard let input = try? search.input.decode(as: PhotoTools.SearchPhotosInput.self) else {
            return nil
        }

        var filters = AppliedFilters(
            dateFrom: input.date_from,
            dateTo: input.date_to,
            mediaType: input.media_type == "any" ? nil : input.media_type,
            favoritesOnly: input.favorites_only ?? false,
            album: input.album?.trimmingCharacters(in: .whitespacesAndNewlines),
            sort: input.sort ?? "newest_first",
            limit: min(max(input.limit ?? 30, 1), PhotoTools.maxLimit)
        )
        if let latitude = input.latitude, let longitude = input.longitude, let radius = input.radius_meters {
            filters.near = GeoCircle(latitude: latitude, longitude: longitude, radiusMeters: radius)
            filters.place = placeName(latitude: latitude, longitude: longitude, in: calls)
        }
        return filters
    }

    /// The name from a successful `geocode_place` result at these coordinates.
    private static func placeName(latitude: Double, longitude: Double, in calls: [ToolCallRecord]) -> String? {
        for call in calls.reversed() where call.name == "geocode_place" && !call.output.isError {
            guard let result = try? JSONDecoder().decode(JSONValue.self, from: Data(call.output.content.utf8)),
                  case .number(let lat)? = result["latitude"],
                  case .number(let lon)? = result["longitude"],
                  case .string(let name)? = result["name"],
                  abs(lat - latitude) < 0.001, abs(lon - longitude) < 0.001
            else { continue }
            return name
        }
        return nil
    }
}
