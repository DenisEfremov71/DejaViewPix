//
//  SearchStatus.swift
//  AlbumAI
//

import Foundation

/// A tool call about to run. The app turns it into a status line, which is more truthful
/// than anything the model says about itself: it describes what is actually happening.
public struct ToolCallStart: Sendable, Equatable {
    public var name: String
    public var input: JSONValue
    /// Calls that finished earlier in this search, used to name the place a search covers.
    public var earlierCalls: [ToolCallRecord]

    public init(name: String, input: JSONValue, earlierCalls: [ToolCallRecord] = []) {
        self.name = name
        self.input = input
        self.earlierCalls = earlierCalls
    }

    /// E.g. "Finding Tofino…" or "Searching videos from July–August 2025 near Tofino…".
    public func statusLine(locale: Locale = .current) -> String {
        switch name {
        case "geocode_place":
            guard case .string(let place)? = input["place"] else { return "Finding the place…" }
            return "Finding \(AppliedFilters.shortName(place))…"
        case "list_albums":
            return "Checking your albums…"
        case "search_photos":
            guard let filters = SearchAnswer.appliedFilters(input: input, geocodes: earlierCalls) else {
                return "Searching your library…"
            }
            return filters.statusLine(locale: locale)
        case SearchAnswer.toolName:
            return "Putting your results together…"
        default:
            return "Working…"
        }
    }
}

extension AppliedFilters {
    /// "Searching favorite videos from July–August 2025 near Tofino…"
    public func statusLine(locale: Locale = .current) -> String {
        var text = "Searching"
        let subject = subject
        let dates = DateRangeText.describe(from: dateFrom, to: dateTo, locale: locale)
        switch (subject, dates) {
        case let (subject?, dates?): text += " \(subject) from \(dates)"
        case let (subject?, nil): text += " \(subject)"
        case let (nil, dates?): text += " \(dates)"
        case (nil, nil): break
        }
        if let album {
            text += " in “\(album)”"
        }
        if near != nil {
            text += " near \(placeShortName ?? "the place")"
        }
        if text == "Searching" {
            text += " your whole library"
        }
        return text + "…"
    }

    /// "favorite videos", "photos", "favorites", or nil when neither filter is set.
    var subject: String? {
        switch (mediaType, favoritesOnly) {
        case ("video"?, true): "favorite videos"
        case ("photo"?, true): "favorite photos"
        case (nil, true): "favorites"
        case ("video"?, false): "videos"
        case ("photo"?, false): "photos"
        default: nil
        }
    }

    /// The first part of the geocoded name: "Whistler" from "Whistler, BC, Canada".
    public var placeShortName: String? {
        place.map(Self.shortName)
    }

    static func shortName(_ place: String) -> String {
        let first = place.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? place
    }
}

/// Human-readable date ranges for YYYY-MM-DD bounds, both inclusive.
public enum DateRangeText {
    /// "July 2025", "July–August 2025", "December 2025–February 2026", "2025",
    /// "Jan 14, 2026", "Jan 14 – Feb 3, 2026", "since Jan 14, 2026" or "until …".
    public static func describe(from: String?, to: String?, locale: Locale = .current) -> String? {
        let start = from.flatMap(day)
        let end = to.flatMap(day)

        switch (start, end) {
        case (nil, nil):
            return nil
        case let (start?, nil):
            return "since \(medium(start, locale))"
        case let (nil, end?):
            return "until \(medium(end, locale))"
        case let (start?, end?):
            if start == end {
                return medium(start, locale)
            }
            let first = calendar.dateComponents([.year, .month, .day], from: start)
            let last = calendar.dateComponents([.year, .month, .day], from: end)
            let wholeMonths = first.day == 1 && calendar.date(byAdding: .day, value: 1, to: end)
                .map { calendar.component(.day, from: $0) == 1 } == true
            guard wholeMonths else {
                return first.year == last.year
                    ? "\(monthDay(start, locale)) – \(medium(end, locale))"
                    : "\(medium(start, locale)) – \(medium(end, locale))"
            }
            if first.month == 1, last.month == 12 {
                return first.year == last.year ? "\(first.year!)" : "\(first.year!)–\(last.year!)"
            }
            if first.year == last.year {
                return first.month == last.month
                    ? "\(month(start, locale)) \(first.year!)"
                    : "\(month(start, locale))–\(month(end, locale)) \(first.year!)"
            }
            return "\(month(start, locale)) \(first.year!)–\(month(end, locale)) \(last.year!)"
        }
    }

    /// Dates here are calendar days, not instants, so they're handled in UTC throughout.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func style(_ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    private static func medium(_ date: Date, _ locale: Locale) -> String {
        date.formatted(style(locale).year().month(.abbreviated).day())
    }

    private static func monthDay(_ date: Date, _ locale: Locale) -> String {
        date.formatted(style(locale).month(.abbreviated).day())
    }

    private static func month(_ date: Date, _ locale: Locale) -> String {
        date.formatted(style(locale).month(.wide))
    }
}
