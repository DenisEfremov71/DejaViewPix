//
//  PlaceGeocoder.swift
//  AlbumAI
//

#if canImport(MapKit)
import CoreLocation
import Foundation
import MapKit

/// `PlaceGeocoding` backed by Apple's geocoder. Uses MapKit's `MKGeocodingRequest` on
/// iOS/macOS 26 and later, and `CLGeocoder` (deprecated there) on earlier versions.
public struct PlaceGeocoder: PlaceGeocoding {
    public init() {}

    public func geocode(_ place: String) async throws -> Place {
        let query = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolError.invalidInput("The place name is empty.")
        }

        if #available(iOS 26.0, macOS 26.0, *) {
            return try await geocodeWithMapKit(query)
        } else {
            return try await geocodeWithCoreLocation(query)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func geocodeWithMapKit(_ query: String) async throws -> Place {
        guard let request = MKGeocodingRequest(addressString: query) else {
            throw ToolError.placeNotFound(query)
        }
        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch {
            try Task.checkCancellation()
            throw ToolError.placeNotFound(query)
        }
        guard let item = items.first else {
            throw ToolError.placeNotFound(query)
        }

        let coordinate = item.location.coordinate
        let addresses = item.addressRepresentations
        let name = item.name ?? query
        return Place(
            name: Self.joinedName([name, addresses?.cityWithContext(.full)]),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: Self.kind(
                name: name,
                category: item.pointOfInterestCategory,
                city: addresses?.cityName,
                country: addresses?.regionName,
                hasStreetAddress: item.address?.shortAddress.map { $0 != addresses?.cityWithContext } ?? false
            )
        )
    }

    private func geocodeWithCoreLocation(_ query: String) async throws -> Place {
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(query)
        } catch {
            try Task.checkCancellation()
            throw ToolError.placeNotFound(query)
        }
        guard let placemark = placemarks.first, let location = placemark.location else {
            throw ToolError.placeNotFound(query)
        }

        let kind: Place.Kind
        if let area = placemark.areasOfInterest?.first {
            kind = Self.kind(name: area, category: nil, city: nil, country: nil, hasStreetAddress: false)
        } else if placemark.thoroughfare != nil {
            kind = .address
        } else if placemark.subLocality != nil {
            kind = .neighborhood
        } else if placemark.locality != nil {
            kind = .city
        } else if placemark.administrativeArea != nil {
            kind = .region
        } else {
            kind = .country
        }

        return Place(
            name: Self.joinedName([placemark.areasOfInterest?.first, placemark.name, placemark.locality,
                                   placemark.administrativeArea, placemark.country]),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            kind: kind
        )
    }

    /// "Whistler, Whistler, BC, Canada" → "Whistler, BC, Canada": the parts often repeat.
    private static func joinedName(_ parts: [String?]) -> String {
        var seen: [String] = []
        for part in parts.compactMap({ $0 }) {
            for piece in part.components(separatedBy: ", ") where !seen.contains(piece) {
                seen.append(piece)
            }
        }
        return seen.joined(separator: ", ")
    }

    /// Classifies a MapKit result. Without a category, compare the result's name with its
    /// address: a name equal to the city is a city, one equal to the country is a country.
    static func kind(
        name: String,
        category: MKPointOfInterestCategory?,
        city: String?,
        country: String?,
        hasStreetAddress: Bool
    ) -> Place.Kind {
        if let category {
            if #available(iOS 18.0, macOS 15.0, *), category == .skiing {
                return .skiArea
            }
            switch category {
            case .beach: return .beach
            case .park: return .park
            case .nationalPark: return .nationalPark
            default: return .pointOfInterest
            }
        }
        if let city, name.localizedCaseInsensitiveCompare(city) == .orderedSame { return .city }
        if let country, name.localizedCaseInsensitiveCompare(country) == .orderedSame { return .country }
        if hasStreetAddress { return .address }
        if city == nil { return .region }
        return .neighborhood
    }
}
#endif
