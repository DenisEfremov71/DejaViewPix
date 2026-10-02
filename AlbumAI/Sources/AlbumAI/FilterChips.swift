//
//  FilterChips.swift
//  AlbumAI
//

import Foundation

/// One filter the app understood from the query, shown as a chip the user can remove or
/// edit. Edits re-run the search locally, without calling the model.
public enum FilterChip: Sendable, Hashable {
    /// YYYY-MM-DD bounds, both inclusive; at least one is set.
    case dates(from: String?, to: String?)
    /// `name` is the geocoded name, when known.
    case place(name: String?, circle: GeoCircle)
    /// "photo" or "video".
    case mediaType(String)
    case favorites
    case album(String)
    case oldestFirst

    public func label(locale: Locale = .current) -> String {
        switch self {
        case let .dates(from, to):
            DateRangeText.describe(from: from, to: to, locale: locale) ?? "Any date"
        case let .place(name, circle):
            "\(name.map(AppliedFilters.shortName) ?? "Map area") · \(Self.radiusText(circle.radiusMeters))"
        case .mediaType(let type):
            type == "video" ? "Videos" : "Photos"
        case .favorites:
            "Favorites"
        case .album(let title):
            title
        case .oldestFirst:
            "Oldest first"
        }
    }

    /// An SF Symbol name.
    public var systemImage: String {
        switch self {
        case .dates: "calendar"
        case .place: "mappin.and.ellipse"
        case .mediaType(let type): type == "video" ? "video" : "photo"
        case .favorites: "heart"
        case .album: "rectangle.stack"
        case .oldestFirst: "arrow.up"
        }
    }

    /// "300 m", "1.5 km", "15 km", "1,000 km" (grouping follows the locale).
    public static func radiusText(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        return "\((meters / 1_000).formatted(.number.precision(.significantDigits(1...3)))) km"
    }
}

extension AppliedFilters {
    /// The chips for this one search, in display order.
    public var chips: [FilterChip] {
        var chips: [FilterChip] = []
        if dateFrom != nil || dateTo != nil {
            chips.append(.dates(from: dateFrom, to: dateTo))
        }
        if let near {
            chips.append(.place(name: place, circle: near))
        }
        if let album {
            chips.append(.album(album))
        }
        if let mediaType {
            chips.append(.mediaType(mediaType))
        }
        if favoritesOnly {
            chips.append(.favorites)
        }
        if sort == "oldest_first" {
            chips.append(.oldestFirst)
        }
        return chips
    }

    /// Clears the filter `old` stands for and, when given, sets `new` instead. Unchanged when
    /// this search doesn't have `old`.
    public func replacing(_ old: FilterChip, with new: FilterChip?) -> AppliedFilters {
        guard chips.contains(old) else { return self }
        var filters = self
        switch old {
        case .dates: filters.dateFrom = nil; filters.dateTo = nil
        case .place: filters.near = nil; filters.place = nil
        case .mediaType: filters.mediaType = nil
        case .favorites: filters.favoritesOnly = false
        case .album: filters.album = nil
        case .oldestFirst: filters.sort = "newest_first"
        }
        switch new {
        case nil: break
        case let .dates(from, to): filters.dateFrom = from; filters.dateTo = to
        case let .place(name, circle): filters.near = circle; filters.place = name
        case .mediaType(let type): filters.mediaType = type
        case .favorites: filters.favoritesOnly = true
        case .album(let title): filters.album = title
        case .oldestFirst: filters.sort = "oldest_first"
        }
        return filters
    }

    /// True when a photo at these coordinates is inside this search's area.
    func contains(latitude: Double, longitude: Double) -> Bool {
        guard let near else { return false }
        return GeoCircle.distance(
            fromLatitude: near.latitude, longitude: near.longitude,
            toLatitude: latitude, longitude: longitude
        ) <= near.radiusMeters
    }
}

extension Array where Element == AppliedFilters {
    /// Every distinct chip across the searches, in order of first appearance.
    public var chips: [FilterChip] {
        var seen = Set<FilterChip>()
        return flatMap(\.chips).filter { seen.insert($0).inserted }
    }

    /// Applies the edit to every search that has `old`, then drops searches that became
    /// identical.
    public func replacing(_ old: FilterChip, with new: FilterChip?) -> [AppliedFilters] {
        var seen = Set<AppliedFilters>()
        return map { $0.replacing(old, with: new) }.filter { seen.insert($0).inserted }
    }

    /// The short name of the first searched place that contains these coordinates, for
    /// VoiceOver labels. Avoids a reverse-geocoding call per photo.
    public func placeName(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return first { $0.place != nil && $0.contains(latitude: latitude, longitude: longitude) }?
            .placeShortName
    }
}

extension GeoCircle {
    /// Great-circle distance in meters (haversine), close enough to CoreLocation's for
    /// deciding whether a photo is inside a search area.
    static func distance(fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Local search

extension PhotoTools {
    /// The `PhotoQuery` a set of applied filters stands for, validated like a tool call.
    public func query(for filters: AppliedFilters) throws -> PhotoQuery {
        try query(from: SearchPhotosInput(
            date_from: filters.dateFrom,
            date_to: filters.dateTo,
            media_type: filters.mediaType,
            favorites_only: filters.favoritesOnly,
            album: filters.album,
            latitude: filters.near?.latitude,
            longitude: filters.near?.longitude,
            radius_meters: filters.near?.radiusMeters,
            limit: filters.limit,
            sort: filters.sort
        ))
    }

    /// Re-runs edited filters against the library directly, without the model: each search
    /// in order, duplicates dropped. No filters at all searches the whole library.
    public func search(_ filters: [AppliedFilters]) async throws -> PhotoSearchResult {
        var matches: [PhotoMatch] = []
        var seen = Set<String>()
        var hasMore = false
        for filters in filters.isEmpty ? [AppliedFilters()] : filters {
            let result = try await library.search(query(for: filters))
            matches += result.matches.filter { seen.insert($0.id).inserted }
            hasMore = hasMore || result.hasMore
        }
        return PhotoSearchResult(matches: matches, hasMore: hasMore)
    }
}
