//
//  PhotoLibrary.swift
//  AlbumAI
//

#if canImport(Photos)
import CoreLocation
import Foundation
import Photos

/// `PhotoSearching` backed by PhotoKit. Assumes the app already has read access; with
/// limited access, only the photos the user picked are visible.
public struct PhotoLibrary: PhotoSearching {
    /// Smart albums worth offering to the model. "Recents" and similar catch-alls are left out.
    static let smartAlbumSubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumSelfPortraits,
        .smartAlbumScreenshots,
        .smartAlbumPanoramas,
        .smartAlbumLivePhotos,
        .smartAlbumDepthEffect,
        .smartAlbumSlomoVideos,
        .smartAlbumTimelapses,
        .smartAlbumBursts,
    ]

    public init() {}

    public func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        try Task.checkCancellation()

        // Location can't go in the predicate, so a location search fetches without a
        // limit and filters in memory. One extra result tells us whether there are more.
        let options = Self.fetchOptions(for: query, fetchLimit: query.near == nil ? query.limit + 1 : 0)

        let assets: PHFetchResult<PHAsset>
        if let title = query.album {
            guard let album = Self.album(titled: title) else {
                throw ToolError.albumNotFound(title)
            }
            assets = PHAsset.fetchAssets(in: album, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }

        let center = query.near.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var matches: [PhotoMatch] = []
        var hasMore = false

        for index in 0..<assets.count {
            if index.isMultiple(of: 500) {
                try Task.checkCancellation()
            }
            let asset = assets.object(at: index)

            var distance: Double?
            if let center, let radius = query.near?.radiusMeters {
                guard let location = asset.location else { continue }
                distance = location.distance(from: center)
                guard distance! <= radius else { continue }
            }

            guard matches.count < query.limit else {
                hasMore = true
                break
            }
            matches.append(PhotoMatch(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                isVideo: asset.mediaType == .video,
                isFavorite: asset.isFavorite,
                distanceMeters: distance
            ))
        }

        return PhotoSearchResult(matches: matches, hasMore: hasMore)
    }

    public func albums() async throws -> [AlbumInfo] {
        try Task.checkCancellation()

        var albums: [AlbumInfo] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle else { return }
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                albums.append(AlbumInfo(title: title, count: count))
            }
        for collection in Self.smartAlbums() {
            guard let title = collection.localizedTitle else { continue }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > 0 {
                albums.append(AlbumInfo(title: title, count: count, isSmartAlbum: true))
            }
        }
        return albums
    }

    /// Details for the grid, in the order of `ids`. IDs that no longer exist are left out.
    /// Runs off the main actor, like every PhotoKit fetch here.
    public func details(for ids: [String]) async -> [PhotoDetails] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PhotoDetails] = [:]
        assets.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = PhotoDetails(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                isVideo: asset.mediaType == .video,
                isFavorite: asset.isFavorite,
                duration: asset.duration,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude
            )
        }
        return ids.compactMap { byID[$0] }
    }

    // MARK: - Helpers

    /// Everything except location goes into the predicate, so PhotoKit does the filtering.
    static func fetchOptions(for query: PhotoQuery, fetchLimit: Int) -> PHFetchOptions {
        var predicates: [NSPredicate] = []
        if let from = query.from {
            predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate))
        }
        if let until = query.until {
            predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate))
        }
        switch query.mediaType {
        case .photo:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case .video:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case nil:
            predicates.append(NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            ))
        }
        if query.favoritesOnly {
            predicates.append(NSPredicate(format: "favorite == YES"))
        }

        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: query.sortOrder == .oldestFirst),
        ]
        options.fetchLimit = fetchLimit
        return options
    }

    /// A user album with this title, or else one of the offered smart albums.
    private static func album(titled title: String) -> PHAssetCollection? {
        var match: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle?.caseInsensitiveCompare(title) == .orderedSame {
                    match = collection
                    stop.pointee = true
                }
            }
        return match ?? smartAlbums().first {
            $0.localizedTitle?.caseInsensitiveCompare(title) == .orderedSame
        }
    }

    private static func smartAlbums() -> [PHAssetCollection] {
        smartAlbumSubtypes.compactMap {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: $0, options: nil).firstObject
        }
    }
}
#endif
