//
//  Scoring.swift
//  EvalKit
//
//  Compares what one run did with what the case expects, field by field.
//

import AlbumAI
import Foundation

/// Everything one run of one case produced, success or not.
public struct RunRecord: Sendable {
    /// Every tool call in order, present_results included.
    public var calls: [ToolCallRecord]
    /// The presented photo IDs; nil when the loop didn't end with a valid answer.
    public var presentedIDs: [String]?
    /// The loop's error, if it threw.
    public var error: String?
    /// The loop ended with `ToolLoopError.noAnswer`: Claude declined to present anything.
    public var endedWithNoAnswer: Bool
    public var metrics: QueryMetrics

    public init(
        calls: [ToolCallRecord],
        presentedIDs: [String]?,
        error: String? = nil,
        endedWithNoAnswer: Bool = false,
        metrics: QueryMetrics
    ) {
        self.calls = calls
        self.presentedIDs = presentedIDs
        self.error = error
        self.endedWithNoAnswer = endedWithNoAnswer
        self.metrics = metrics
    }
}

/// The arguments of a search_photos call, normalized: "any" and absent media types are nil,
/// absent favorites_only is false, albums are trimmed.
public struct ObservedSearch: Sendable, Equatable, Codable {
    public var dateFrom: String?
    public var dateTo: String?
    public var mediaType: String?
    public var favoritesOnly: Bool
    public var album: String?
    public var latitude: Double?
    public var longitude: Double?
    public var radiusMeters: Double?

    public init(input: JSONValue) {
        func string(_ key: String) -> String? {
            if case .string(let value)? = input[key] { value } else { nil }
        }
        func number(_ key: String) -> Double? {
            if case .number(let value)? = input[key] { value } else { nil }
        }
        dateFrom = string("date_from")
        dateTo = string("date_to")
        let media = string("media_type")
        mediaType = media == "any" ? nil : media
        if case .bool(let favorites)? = input["favorites_only"] {
            favoritesOnly = favorites
        } else {
            favoritesOnly = false
        }
        let album = string("album")?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album?.isEmpty == true ? nil : album
        latitude = number("latitude")
        longitude = number("longitude")
        radiusMeters = number("radius_meters")
    }
}

public enum Field: String, Sendable, Codable, CaseIterable {
    case dates
    case place
    case mediaType = "media_type"
    case favoritesOnly = "favorites_only"
    case album
}

public struct RunScore: Sendable {
    /// Only the fields that were scored in this run.
    public var fields: [Field: Bool]
    public var behaviorPassed: Bool
    /// Behavior and every scored field passed.
    public var passed: Bool
    /// Why it failed, in words, for the report.
    public var problems: [String]
    /// The first valid search_photos call, if there was one.
    public var observed: ObservedSearch?
}

public enum Scorer {
    public static func score(_ testCase: ResolvedCase, _ run: RunRecord) -> RunScore {
        let searches = run.calls.filter { $0.name == "search_photos" }
        let observed = searches.first { !$0.output.isError }.map { ObservedSearch(input: $0.input) }
        let presentedNothing = run.presentedIDs?.isEmpty == true || run.endedWithNoAnswer

        var problems: [String] = []
        var fields: [Field: Bool] = [:]
        let behaviorPassed: Bool

        switch testCase.behavior {
        case .search:
            if observed == nil {
                problems.append(searches.isEmpty ? "no search_photos call" : "no valid search_photos call")
            }
            if run.presentedIDs == nil {
                problems.append("no answer: \(run.error ?? "the loop ended without present_results")")
            }
            behaviorPassed = observed != nil && run.presentedIDs != nil
            if let expect = testCase.expect {
                fields = observed.map { compare($0, expect, testCase: testCase) }
                    ?? Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0, false) })
            }

        case .noPhotos:
            if !presentedNothing {
                problems.append(run.presentedIDs == nil
                    ? "loop failed: \(run.error ?? "unknown error")"
                    : "presented \(run.presentedIDs!.count) photos")
            }
            behaviorPassed = presentedNothing
            if let observed, let expect = testCase.expect {
                fields = compare(observed, expect, testCase: testCase)
            }

        case .noSearch:
            if !searches.isEmpty {
                problems.append("searched \(searches.count) time(s)")
            }
            if !presentedNothing {
                problems.append(run.presentedIDs == nil
                    ? "loop failed: \(run.error ?? "unknown error")"
                    : "presented \(run.presentedIDs!.count) photos")
            }
            behaviorPassed = searches.isEmpty && presentedNothing
        }

        for field in Field.allCases where fields[field] == false {
            problems.append("\(field.rawValue) wrong")
        }
        return RunScore(
            fields: fields,
            behaviorPassed: behaviorPassed,
            passed: behaviorPassed && fields.values.allSatisfy { $0 },
            problems: problems,
            observed: observed
        )
    }

    static func compare(_ observed: ObservedSearch, _ expect: ExpectedSearch, testCase: ResolvedCase) -> [Field: Bool] {
        [
            .dates: expect.dates.values.contains { datesMatch($0, observed) },
            .place: expect.place.values.contains { placeMatches($0, observed, defaultKm: testCase.withinKm) },
            .mediaType: expect.mediaType.values.contains(observed.mediaType),
            .favoritesOnly: expect.favoritesOnly.values.contains(observed.favoritesOnly),
            .album: expect.album.values.contains { expected in
                switch (expected, observed.album) {
                case (nil, nil): true
                case let (expected?, album?): expected.caseInsensitiveCompare(album) == .orderedSame
                default: false
                }
            },
        ]
    }

    static func datesMatch(_ expected: ExpectedDates?, _ observed: ObservedSearch) -> Bool {
        guard let expected else {
            return observed.dateFrom == nil && observed.dateTo == nil
        }
        return endMatches(expected.from, observed.dateFrom, tolerance: expected.toleranceDays)
            && endMatches(expected.to, observed.dateTo, tolerance: expected.toleranceDays)
    }

    private static func endMatches(_ expected: String?, _ observed: String?, tolerance: Int) -> Bool {
        switch (expected, observed) {
        case (nil, nil):
            return true
        case let (expected?, observed?):
            guard let difference = DayMath.days(from: expected, to: observed) else { return false }
            return abs(difference) <= tolerance
        default:
            return false
        }
    }

    static func placeMatches(_ expected: ExpectedPlace?, _ observed: ObservedSearch, defaultKm: Double) -> Bool {
        guard let expected else {
            return observed.latitude == nil && observed.longitude == nil
        }
        guard let latitude = observed.latitude, let longitude = observed.longitude else { return false }
        let km = distanceMeters(expected.latitude, expected.longitude, latitude, longitude) / 1_000
        return km <= (expected.withinKm ?? defaultKm)
    }

    /// Haversine distance in meters.
    static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
