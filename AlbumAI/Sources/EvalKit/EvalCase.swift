//
//  EvalCase.swift
//  EvalKit
//
//  The dataset in evals/cases.json. The matching rules are in evals/README.md.
//

import Foundation

public struct Dataset: Decodable, Sendable {
    public var version: Int
    public var written: String
    public var defaults: Defaults
    public var cases: [EvalCase]

    public struct Defaults: Decodable, Sendable {
        public var today: String
        public var timeZone: String
        public var behavior: Behavior
        public var withinKm: Double

        enum CodingKeys: String, CodingKey {
            case today
            case timeZone = "time_zone"
            case behavior
            case withinKm = "within_km"
        }
    }

    public static func load(from url: URL) throws -> Dataset {
        try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: url))
    }

    /// The cases with every default filled in.
    public func resolved() throws -> [ResolvedCase] {
        try cases.map { item in
            let zoneID = item.timeZone ?? defaults.timeZone
            guard let timeZone = TimeZone(identifier: zoneID) else {
                throw DatasetError.unknownTimeZone(item.id, zoneID)
            }
            let today = item.today ?? defaults.today
            guard DayMath.day(today) != nil else {
                throw DatasetError.badDate(item.id, today)
            }
            return ResolvedCase(
                id: item.id,
                split: item.split,
                query: item.query,
                today: today,
                timeZone: timeZone,
                behavior: item.behavior ?? defaults.behavior,
                withinKm: item.withinKm ?? defaults.withinKm,
                expect: item.expect,
                tags: item.tags
            )
        }
    }
}

public enum DatasetError: LocalizedError, Equatable {
    case unknownTimeZone(String, String)
    case badDate(String, String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTimeZone(id, zone): "\(id): unknown time zone \(zone)"
        case let .badDate(id, date): "\(id): today must be YYYY-MM-DD, not \(date)"
        }
    }
}

public enum Split: String, Codable, Sendable {
    case dev, test
}

public enum Behavior: String, Codable, Sendable {
    /// A valid search_photos call, and the loop ends with present_results.
    case search
    /// No photos presented; a search, if any, must match `expect`.
    case noPhotos = "no_photos"
    /// No search_photos call and no photos; an empty answer or a clean `.noAnswer` error.
    case noSearch = "no_search"
}

public struct EvalCase: Decodable, Sendable {
    public var id: String
    public var split: Split
    public var query: String
    public var today: String?
    public var timeZone: String?
    public var behavior: Behavior?
    public var withinKm: Double?
    public var expect: ExpectedSearch?
    public var tags: [String]
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case id, split, query, today, behavior, expect, tags, note
        case timeZone = "time_zone"
        case withinKm = "within_km"
    }
}

public struct ResolvedCase: Sendable {
    public var id: String
    public var split: Split
    public var query: String
    /// YYYY-MM-DD in `timeZone`.
    public var today: String
    public var timeZone: TimeZone
    public var behavior: Behavior
    /// Place tolerance when the expected place doesn't set its own.
    public var withinKm: Double
    public var expect: ExpectedSearch?
    public var tags: [String]

    public init(
        id: String,
        split: Split = .dev,
        query: String,
        today: String = "2026-10-02",
        timeZone: TimeZone = TimeZone(identifier: "America/Vancouver")!,
        behavior: Behavior = .search,
        withinKm: Double = 25,
        expect: ExpectedSearch?,
        tags: [String] = []
    ) {
        self.id = id
        self.split = split
        self.query = query
        self.today = today
        self.timeZone = timeZone
        self.behavior = behavior
        self.withinKm = withinKm
        self.expect = expect
        self.tags = tags
    }

    /// Noon on `today` in the case's time zone: the "now" the system prompt is built with.
    public var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = today.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }
}

/// The arguments the first valid search_photos call should have.
public struct ExpectedSearch: Decodable, Sendable {
    public var dates: Accepted<ExpectedDates>
    public var place: Accepted<ExpectedPlace>
    public var mediaType: Accepted<String>
    public var favoritesOnly: Accepted<Bool>
    public var album: Accepted<String>

    public init(
        dates: Accepted<ExpectedDates> = .none,
        place: Accepted<ExpectedPlace> = .none,
        mediaType: Accepted<String> = .none,
        favoritesOnly: Accepted<Bool> = [false],
        album: Accepted<String> = .none
    ) {
        self.dates = dates
        self.place = place
        self.mediaType = mediaType
        self.favoritesOnly = favoritesOnly
        self.album = album
    }

    enum CodingKeys: String, CodingKey {
        case dates, place, album
        case mediaType = "media_type"
        case favoritesOnly = "favorites_only"
    }
}

public struct ExpectedDates: Decodable, Sendable, Equatable {
    /// YYYY-MM-DD; nil means that end must be absent.
    public var from: String?
    public var to: String?
    public var toleranceDays: Int

    public init(from: String?, to: String?, toleranceDays: Int = 0) {
        self.from = from
        self.to = to
        self.toleranceDays = toleranceDays
    }

    enum CodingKeys: String, CodingKey {
        case from, to
        case toleranceDays = "tolerance_days"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        toleranceDays = try container.decodeIfPresent(Int.self, forKey: .toleranceDays) ?? 0
    }
}

public struct ExpectedPlace: Decodable, Sendable, Equatable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Overrides the case's tolerance.
    public var withinKm: Double?

    public init(name: String, latitude: Double, longitude: Double, withinKm: Double? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.withinKm = withinKm
    }

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude
        case withinKm = "within_km"
    }
}

/// The values a field may have. `null` in JSON means "must not be set"; `{"one_of": [...]}`
/// lists several acceptable values, `null` included.
public struct Accepted<Value: Decodable & Sendable>: Decodable, Sendable, ExpressibleByArrayLiteral {
    public var values: [Value?]

    public init(_ values: [Value?]) {
        self.values = values
    }

    public init(arrayLiteral values: Value?...) {
        self.values = values
    }

    /// The field must not be set.
    public static var none: Accepted { Accepted([nil]) }

    private enum OneOfKey: String, CodingKey {
        case oneOf = "one_of"
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: OneOfKey.self), container.contains(.oneOf) {
            values = try container.decode([Value?].self, forKey: .oneOf)
            return
        }
        let single = try decoder.singleValueContainer()
        values = single.decodeNil() ? [nil] : [try single.decode(Value.self)]
    }
}

/// Calendar-day arithmetic for YYYY-MM-DD strings, in UTC so days never shift.
enum DayMath {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }

    /// Whole days from `a` to `b`, or nil if either isn't a valid day.
    static func days(from a: String, to b: String) -> Int? {
        guard let start = day(a), let end = day(b) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }
}
