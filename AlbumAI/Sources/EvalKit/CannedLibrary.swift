//
//  CannedLibrary.swift
//  EvalKit
//

import AlbumAI
import Foundation

/// A fixed photo library for evals. It filters like PhotoKit would (dates, media type,
/// favorites, album, distance), so impossible dates find nothing and answers look real, but
/// the scoring only looks at the arguments Claude passed.
public actor CannedLibrary: PhotoSearching {
    public struct Photo: Sendable {
        public var id: String
        public var date: Date
        public var latitude: Double?
        public var longitude: Double?
        public var isVideo = false
        public var isFavorite = false
        public var albums: [String] = []
    }

    public struct Album: Sendable {
        public var title: String
        public var isSmartAlbum: Bool
    }

    private let photos: [Photo]
    private let albumList: [Album]

    public init(photos: [Photo] = CannedLibrary.standardPhotos, albums: [Album] = CannedLibrary.standardAlbums) {
        self.photos = photos
        self.albumList = albums
    }

    public func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        if let title = query.album, !albumList.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            throw ToolError.albumNotFound(title)
        }

        var matches: [PhotoMatch] = []
        for photo in photos {
            if let from = query.from, photo.date < from { continue }
            if let until = query.until, photo.date >= until { continue }
            if query.mediaType == .video, !photo.isVideo { continue }
            if query.mediaType == .photo, photo.isVideo { continue }
            if query.favoritesOnly, !photo.isFavorite { continue }
            if let title = query.album, !photo.albums.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                continue
            }
            var distance: Double?
            if let near = query.near {
                guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
                distance = Scorer.distanceMeters(near.latitude, near.longitude, latitude, longitude)
                guard distance! <= near.radiusMeters else { continue }
            }
            matches.append(PhotoMatch(
                id: photo.id,
                creationDate: photo.date,
                isVideo: photo.isVideo,
                isFavorite: photo.isFavorite,
                distanceMeters: distance
            ))
        }

        matches.sort { a, b in
            query.sortOrder == .oldestFirst ? a.creationDate! < b.creationDate! : a.creationDate! > b.creationDate!
        }
        let hasMore = matches.count > query.limit
        return PhotoSearchResult(matches: Array(matches.prefix(query.limit)), hasMore: hasMore)
    }

    public func albums() async throws -> [AlbumInfo] {
        albumList.map { album in
            AlbumInfo(
                title: album.title,
                count: photos.filter { $0.albums.contains(album.title) }.count,
                isSmartAlbum: album.isSmartAlbum
            )
        }
    }

    // MARK: - The standard library

    public static let standardAlbums = [
        Album(title: "Hiking", isSmartAlbum: false),
        Album(title: "Screenshots", isSmartAlbum: true),
        Album(title: "Selfies", isSmartAlbum: true),
    ]

    /// Places and dates the cases ask about, plus a few that no case should match.
    public static let standardPhotos: [Photo] = [
        photo("whistler-village", "2026-01-14T10:30:00-08:00", 50.1163, -122.9574),
        photo("blackcomb-peak", "2026-02-07T13:15:00-08:00", 50.0950, -122.8890, favorite: true),
        photo("whistler-creekside", "2025-12-28T09:45:00-08:00", 50.0950, -122.9890, video: true),
        photo("whistler-summer", "2025-07-19T16:00:00-07:00", 50.1163, -122.9574),
        photo("whistler-winter-2024", "2025-01-18T11:00:00-08:00", 50.1163, -122.9574),
        photo("stanley-park", "2026-01-03T11:00:00-08:00", 49.3043, -123.1443, favorite: true),
        photo("vancouver-canada-day", "2026-07-01T21:00:00-07:00", 49.2827, -123.1207),
        photo("squamish-christmas", "2025-12-27T14:00:00-08:00", 49.7016, -123.1558, video: true),
        photo("squamish-chief", "2026-05-16T09:00:00-07:00", 49.6806, -123.1458, albums: ["Hiking"]),
        photo("garibaldi-lake", "2025-08-23T11:00:00-07:00", 49.9583, -123.1236, albums: ["Hiking"]),
        photo("eiffel-tower", "2026-06-12T19:20:00+02:00", 48.8584, 2.2945),
        photo("paris-selfie", "2026-06-13T10:00:00+02:00", 48.8606, 2.3376, albums: ["Selfies"]),
        photo("seine-video", "2026-06-14T21:30:00+02:00", 48.8530, 2.3499, video: true),
        photo("tofino-sunset", "2026-08-09T18:40:00-07:00", 49.0806, -125.7576, video: true, favorite: true),
        photo("tofino-2025", "2025-07-05T12:00:00-07:00", 49.1530, -125.9066),
        photo("victoria-harbour", "2026-04-18T13:00:00-07:00", 48.4222, -123.3681),
        photo("melbourne", "2025-11-02T15:00:00+11:00", -37.8136, 144.9631),
        photo("christmas-2024", "2024-12-25T09:00:00-08:00", 49.2827, -123.1207, favorite: true),
        photo("last-weekend", "2026-09-26T12:00:00-07:00", 49.2827, -123.1207),
        photo("september-video", "2026-09-10T17:00:00-07:00", 49.2827, -123.1207, video: true),
        photo("two-weeks", "2026-09-20T10:00:00-07:00", 49.2827, -123.1207),
        photo("screenshot-2026", "2026-03-03T08:00:00-08:00", nil, nil, albums: ["Screenshots"]),
        photo("screenshot-2025", "2025-11-20T08:00:00-08:00", nil, nil, albums: ["Screenshots"]),
        photo("selfie-2025", "2025-05-02T18:00:00-07:00", nil, nil, albums: ["Selfies"]),
        photo("no-location", "2026-01-20T08:00:00-08:00", nil, nil),
    ]

    private static func photo(
        _ id: String,
        _ date: String,
        _ latitude: Double?,
        _ longitude: Double?,
        video: Bool = false,
        favorite: Bool = false,
        albums: [String] = []
    ) -> Photo {
        Photo(
            id: "canned/\(id)",
            date: try! Date(date, strategy: .iso8601),
            latitude: latitude,
            longitude: longitude,
            isVideo: video,
            isFavorite: favorite,
            albums: albums
        )
    }
}

/// Wraps a geocoder so each place string is looked up once per eval run: fewer network
/// calls, no throttling, and the same answer for the same string across runs.
public actor CachingGeocoder: PlaceGeocoding {
    private let base: any PlaceGeocoding
    private var cache: [String: Result<Place, ToolError>] = [:]

    public init(_ base: any PlaceGeocoding) {
        self.base = base
    }

    public func geocode(_ place: String) async throws -> Place {
        let key = place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cache[key] {
            return try cached.get()
        }
        do {
            let result = try await base.geocode(place)
            cache[key] = .success(result)
            return result
        } catch let error as ToolError {
            cache[key] = .failure(error)
            throw error
        }
    }

    /// Every lookup and what it resolved to, for the report.
    public var lookups: [String: String] {
        cache.mapValues { result in
            switch result {
            case .success(let place):
                "\(place.name) (\(place.latitude), \(place.longitude), \(place.kind.rawValue))"
            case .failure(let error):
                "error: \(error.localizedDescription)"
            }
        }
    }
}
