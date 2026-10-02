//
//  PhotoSearching.swift
//  AlbumAI
//

import Foundation

/// The photo library, as the tools see it. `PhotoLibrary` wraps PhotoKit; tests and evals
/// use a fake.
public protocol PhotoSearching: Sendable {
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult
    func albums() async throws -> [AlbumInfo]
}

/// Turns a place name into a search area. `PlaceGeocoder` wraps MapKit.
public protocol PlaceGeocoding: Sendable {
    func geocode(_ place: String) async throws -> Place
}

public struct PhotoQuery: Sendable, Equatable {
    public enum MediaType: String, Sendable, Equatable {
        case photo, video
    }

    public enum SortOrder: String, Sendable, Equatable {
        case newestFirst, oldestFirst
    }

    /// Inclusive lower bound on the creation date.
    public var from: Date?
    /// Exclusive upper bound on the creation date.
    public var until: Date?
    /// Nil means photos and videos.
    public var mediaType: MediaType?
    public var favoritesOnly: Bool
    /// Exact album title (case-insensitive). Nil searches the whole library.
    public var album: String?
    /// Photos without a location are excluded when this is set.
    public var near: GeoCircle?
    public var limit: Int
    public var sortOrder: SortOrder

    public init(
        from: Date? = nil,
        until: Date? = nil,
        mediaType: MediaType? = nil,
        favoritesOnly: Bool = false,
        album: String? = nil,
        near: GeoCircle? = nil,
        limit: Int = 30,
        sortOrder: SortOrder = .newestFirst
    ) {
        self.from = from
        self.until = until
        self.mediaType = mediaType
        self.favoritesOnly = favoritesOnly
        self.album = album
        self.near = near
        self.limit = limit
        self.sortOrder = sortOrder
    }
}

public struct GeoCircle: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double

    public init(latitude: Double, longitude: Double, radiusMeters: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }
}

public struct PhotoMatch: Sendable, Equatable {
    /// The PHAsset local identifier.
    public var id: String
    public var creationDate: Date?
    public var isVideo: Bool
    public var isFavorite: Bool
    /// Distance from the center of `PhotoQuery.near`, when the query had one.
    public var distanceMeters: Double?

    public init(
        id: String,
        creationDate: Date?,
        isVideo: Bool = false,
        isFavorite: Bool = false,
        distanceMeters: Double? = nil
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.distanceMeters = distanceMeters
    }
}

public struct PhotoSearchResult: Sendable, Equatable {
    public var matches: [PhotoMatch]
    /// True when more photos matched than `PhotoQuery.limit`.
    public var hasMore: Bool

    public init(matches: [PhotoMatch], hasMore: Bool) {
        self.matches = matches
        self.hasMore = hasMore
    }
}

public struct AlbumInfo: Sendable, Equatable {
    public var title: String
    public var count: Int
    /// True for the albums Photos maintains itself, like Selfies or Screenshots.
    public var isSmartAlbum: Bool

    public init(title: String, count: Int, isSmartAlbum: Bool = false) {
        self.title = title
        self.count = count
        self.isSmartAlbum = isSmartAlbum
    }
}

public struct Place: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case pointOfInterest = "point_of_interest"
        case beach, park
        case nationalPark = "national_park"
        case skiArea = "ski_area"
        case address, neighborhood, city, region, country

        /// How far from the center a photo can be and still count as taken "at" the place.
        public var radiusMeters: Double {
            switch self {
            case .address: 300
            case .beach: 1_500
            case .pointOfInterest: 2_000
            case .park, .neighborhood: 3_000
            case .skiArea: 10_000
            case .city: 15_000
            case .nationalPark: 30_000
            case .region: 200_000
            case .country: 1_000_000
            }
        }
    }

    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var kind: Kind

    public init(name: String, latitude: Double, longitude: Double, kind: Kind) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.kind = kind
    }

    public var radiusMeters: Double { kind.radiusMeters }
}
