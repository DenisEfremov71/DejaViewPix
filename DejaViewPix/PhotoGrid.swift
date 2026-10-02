//
//  PhotoGrid.swift
//  DejaViewPix
//

import AlbumAI
import os
import Photos
import SwiftUI

/// Square thumbnails sized to the screen: about 110 pt per column, at least three columns.
struct PhotoGrid: View {
    let photos: [PhotoDetails]
    /// Used to name the place in each photo's VoiceOver label.
    let filters: [AppliedFilters]

    @State private var loader = ThumbnailLoader()
    @State private var width: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    private let spacing: CGFloat = 2

    private var columnCount: Int {
        max(3, Int((width + spacing) / (110 + spacing)))
    }

    /// The cell size in pixels, so PhotoKit decodes no more than the cell can show.
    private var targetSize: CGSize {
        let count = CGFloat(columnCount)
        let side = max(0, (width - spacing * (count - 1)) / count) * displayScale
        return CGSize(width: side.rounded(.up), height: side.rounded(.up))
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
            ForEach(photos) { photo in
                PhotoCell(
                    photo: photo,
                    place: filters.placeName(latitude: photo.latitude, longitude: photo.longitude),
                    loader: loader,
                    targetSize: targetSize
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: CachingRequest(ids: photos.map(\.id), targetSize: targetSize)) {
            guard targetSize.width > 0 else { return }
            await loader.startCaching(ids: photos.map(\.id), targetSize: targetSize)
        }
    }

    private struct CachingRequest: Equatable {
        var ids: [String]
        var targetSize: CGSize
    }
}

private struct PhotoCell: View {
    let photo: PhotoDetails
    let place: String?
    let loader: ThumbnailLoader
    let targetSize: CGSize

    @State private var image: UIImage?
    @State private var imageID: String?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image, imageID == photo.id {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // Keeps the overflow of a non-square image out of the cell's frame.
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
            .clipped()
            .contentShape(.rect)
            .overlay(alignment: .bottom) { badges }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isImage)
            // One task per cell and size: when the cell goes away or shows another photo,
            // the task is cancelled and so is its PhotoKit request, so a late image can never
            // land in the wrong cell.
            .task(id: ThumbnailRequest(id: photo.id, targetSize: targetSize)) {
                guard targetSize.width > 0 else { return }
                for await image in await loader.thumbnails(for: photo.id, targetSize: targetSize) {
                    self.image = image
                    imageID = photo.id
                }
            }
    }

    @ViewBuilder
    private var badges: some View {
        if photo.isVideo || photo.isFavorite {
            HStack(spacing: 4) {
                if photo.isFavorite {
                    Image(systemName: "heart.fill")
                }
                Spacer(minLength: 0)
                if photo.isVideo {
                    Text(Duration.seconds(photo.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        }
    }

    /// "Video, 0:12, January 14, 2026 at 10:30 AM, near Whistler, favorite".
    private var accessibilityLabel: String {
        var parts = [photo.isVideo ? "Video" : "Photo"]
        if photo.isVideo {
            parts.append(Duration.seconds(photo.duration.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
        }
        if let date = photo.creationDate {
            parts.append(date.formatted(date: .long, time: .shortened))
        }
        if let place {
            parts.append("near \(place)")
        }
        if photo.isFavorite {
            parts.append("favorite")
        }
        return parts.joined(separator: ", ")
    }

    private struct ThumbnailRequest: Equatable {
        var id: String
        var targetSize: CGSize
    }
}

/// Thumbnails through one `PHCachingImageManager`. It isn't tied to the main actor: asset
/// fetches run on the concurrent pool, and PhotoKit calls back on threads of its choosing.
nonisolated final class ThumbnailLoader: @unchecked Sendable {
    private let manager = PHCachingImageManager()
    private let assets = OSAllocatedUnfairLock<[String: PHAsset]>(initialState: [:])

    /// The same options for caching and requests, or the cache isn't used.
    private let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        // A quick low-quality image first, then the final one.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()

    /// Pre-decodes thumbnails for the whole result set, replacing the previous one.
    @concurrent
    func startCaching(ids: [String], targetSize: CGSize) async {
        let found = fetch(ids)
        manager.stopCachingImagesForAllAssets()
        manager.startCachingImages(for: found, targetSize: targetSize, contentMode: .aspectFill, options: options)
    }

    /// Yields a degraded image, then the final one. Ending the iteration cancels the request.
    @concurrent
    func thumbnails(for id: String, targetSize: CGSize) async -> AsyncStream<UIImage> {
        let asset = assets.withLock { $0[id] } ?? fetch([id]).first
        let manager = manager
        let options = options
        return AsyncStream { continuation in
            guard let asset else {
                continuation.finish()
                return
            }
            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let image {
                    continuation.yield(image)
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestID)
            }
        }
    }

    private func fetch(_ ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let found = (0..<result.count).map(result.object(at:))
        assets.withLock { cache in
            for asset in found {
                cache[asset.localIdentifier] = asset
            }
        }
        return found
    }
}
