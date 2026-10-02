//
//  Report.swift
//  EvalKit
//

import AlbumAI
import Foundation

/// The scorecard, written as JSON and as a markdown table.
public struct Report: Codable, Sendable {
    public var date: String
    /// The model that was requested.
    public var model: String
    /// The model IDs the API reported, e.g. the dated Haiku ID.
    public var reportedModels: [String]
    /// A hash of the system prompt and tool definitions, to tell prompt versions apart.
    public var promptFingerprint: String
    public var runsPerCase: Int
    public var splits: [String]
    public var summary: Summary
    public var cases: [CaseReport]
    /// Each place string Claude geocoded and what it resolved to.
    public var geocodes: [String: String]

    public struct Summary: Codable, Sendable {
        public var cases: Int
        public var runs: Int
        public var casesPassed: Int
        public var casesFlaky: Int
        public var casesFailed: Int
        /// Runs where the behavior and every scored field matched.
        public var exactMatchRate: Double
        /// Per field: correct runs / runs where the field was scored.
        public var fieldAccuracy: [String: Double]
        public var behaviorAccuracy: Double
        public var averageLatencySeconds: Double
        public var p95LatencySeconds: Double
        public var averageRounds: Double
        public var averageInputTokens: Double
        public var averageOutputTokens: Double
        /// Nil when a model isn't in the price table.
        public var averageCostUSD: Double?
        public var totalCostUSD: Double?
    }

    public struct CaseReport: Codable, Sendable {
        public var id: String
        public var split: String
        public var query: String
        public var tags: [String]
        public var status: CaseResult.Status
        public var runs: [RunReport]
    }

    public struct RunReport: Codable, Sendable {
        public var passed: Bool
        public var problems: [String]
        public var fields: [String: Bool]
        public var observed: ObservedSearch?
        public var presentedCount: Int?
        public var error: String?
        public var rounds: Int
        public var latencySeconds: Double
        public var inputTokens: Int
        public var outputTokens: Int
        public var costUSD: Double?
    }

    public init(
        results: [CaseResult],
        model: String,
        promptFingerprint: String,
        runsPerCase: Int,
        geocodes: [String: String] = [:],
        date: Date = .now
    ) {
        self.date = date.formatted(.iso8601)
        self.model = model
        self.promptFingerprint = promptFingerprint
        self.runsPerCase = runsPerCase
        self.geocodes = geocodes
        splits = Array(Set(results.map(\.testCase.split.rawValue))).sorted()

        let records = results.flatMap(\.records)
        let scores = results.flatMap(\.scores)
        reportedModels = Array(Set(records.map(\.metrics.model))).sorted()

        var fieldAccuracy: [String: Double] = [:]
        for field in Field.allCases {
            let scored = scores.compactMap { $0.fields[field] }
            if !scored.isEmpty {
                fieldAccuracy[field.rawValue] = Double(scored.filter { $0 }.count) / Double(scored.count)
            }
        }
        let latencies = records.map { $0.metrics.latency / .seconds(1) }
        let costs = records.map(\.metrics.cost)
        let knownCosts = costs.allSatisfy { $0 != nil } ? costs.compactMap { $0 } : nil

        summary = Summary(
            cases: results.count,
            runs: records.count,
            casesPassed: results.filter { $0.status == .pass }.count,
            casesFlaky: results.filter { $0.status == .flaky }.count,
            casesFailed: results.filter { $0.status == .fail }.count,
            exactMatchRate: Self.rate(scores.map(\.passed)),
            fieldAccuracy: fieldAccuracy,
            behaviorAccuracy: Self.rate(scores.map(\.behaviorPassed)),
            averageLatencySeconds: Self.mean(latencies),
            p95LatencySeconds: Self.percentile(latencies, 0.95),
            averageRounds: Self.mean(records.map { Double($0.metrics.rounds) }),
            averageInputTokens: Self.mean(records.map { Double($0.metrics.usage.inputTokens) }),
            averageOutputTokens: Self.mean(records.map { Double($0.metrics.usage.outputTokens) }),
            averageCostUSD: knownCosts.map(Self.mean),
            totalCostUSD: knownCosts.map { $0.reduce(0, +) }
        )

        cases = results.map { result in
            CaseReport(
                id: result.testCase.id,
                split: result.testCase.split.rawValue,
                query: result.testCase.query,
                tags: result.testCase.tags,
                status: result.status,
                runs: zip(result.records, result.scores).map { record, score in
                    RunReport(
                        passed: score.passed,
                        problems: score.problems,
                        fields: Dictionary(uniqueKeysWithValues: score.fields.map { ($0.key.rawValue, $0.value) }),
                        observed: score.observed,
                        presentedCount: record.presentedIDs?.count,
                        error: record.error,
                        rounds: record.metrics.rounds,
                        latencySeconds: record.metrics.latency / .seconds(1),
                        inputTokens: record.metrics.usage.inputTokens,
                        outputTokens: record.metrics.usage.outputTokens,
                        costUSD: record.metrics.cost
                    )
                }
            )
        }
    }

    // MARK: - Statistics

    static func rate(_ values: [Bool]) -> Double {
        values.isEmpty ? 0 : Double(values.filter { $0 }.count) / Double(values.count)
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile: the smallest value with at least `p` of the values at or
    /// below it.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // MARK: - Output

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        let s = summary
        var lines = [
            "# Eval scorecard",
            "",
            "- Date: \(date)",
            "- Model: \(reportedModels.joined(separator: ", ")) (requested `\(model)`)",
            "- Prompt fingerprint: `\(promptFingerprint)`",
            "- Splits: \(splits.joined(separator: ", ")) · \(s.cases) cases × \(runsPerCase) runs = \(s.runs) runs",
            "",
            "| Metric | Value |",
            "|---|---|",
            "| Cases passed / flaky / failed | \(s.casesPassed) / \(s.casesFlaky) / \(s.casesFailed) |",
            "| Exact-match rate (runs) | \(Self.percent(s.exactMatchRate)) |",
            "| Behavior | \(Self.percent(s.behaviorAccuracy)) |",
        ]
        for field in Field.allCases {
            if let accuracy = s.fieldAccuracy[field.rawValue] {
                lines.append("| Field: \(field.rawValue) | \(Self.percent(accuracy)) |")
            }
        }
        lines += [
            "| Average latency | \(Self.seconds(s.averageLatencySeconds)) |",
            "| p95 latency | \(Self.seconds(s.p95LatencySeconds)) |",
            "| Average rounds | \(Self.number(s.averageRounds, digits: 2)) |",
            "| Average tokens in / out | \(Self.number(s.averageInputTokens, digits: 0)) / \(Self.number(s.averageOutputTokens, digits: 0)) |",
            "| Cost per query | \(s.averageCostUSD.map(Self.dollars) ?? "unknown") |",
            "| Total cost | \(s.totalCostUSD.map(Self.dollars) ?? "unknown") |",
            "",
            "## Cases",
            "",
            "| Case | Status | Query | Problems |",
            "|---|---|---|---|",
        ]
        for item in cases {
            let problems = Array(Set(item.runs.flatMap(\.problems))).sorted().joined(separator: "; ")
            let status = item.status == .pass ? "pass" : "**\(item.status.rawValue)**"
            lines.append("| \(item.id) | \(status) | \(item.query.replacingOccurrences(of: "|", with: "\\|")) | \(problems) |")
        }

        let failing = cases.filter { $0.status != .pass }
        if !failing.isEmpty {
            lines += ["", "## What the failing runs searched for", ""]
            for item in failing {
                for (index, run) in item.runs.enumerated() where !run.passed {
                    lines.append("- **\(item.id) #\(index + 1)**: \(Self.describe(run))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func describe(_ run: RunReport) -> String {
        var parts: [String] = []
        if let observed = run.observed {
            var search: [String] = []
            if observed.dateFrom != nil || observed.dateTo != nil {
                search.append("dates \(observed.dateFrom ?? "…") to \(observed.dateTo ?? "…")")
            }
            if let latitude = observed.latitude, let longitude = observed.longitude {
                search.append(String(format: "near %.4f, %.4f", latitude, longitude))
            }
            if let mediaType = observed.mediaType { search.append(mediaType) }
            if observed.favoritesOnly { search.append("favorites") }
            if let album = observed.album { search.append("album “\(album)”") }
            parts.append("searched " + (search.isEmpty ? "the whole library" : search.joined(separator: ", ")))
        } else {
            parts.append("no valid search")
        }
        if let count = run.presentedCount {
            parts.append("presented \(count)")
        }
        if let error = run.error {
            parts.append("error: \(error)")
        }
        return parts.joined(separator: " · ")
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    static func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(1)).locale(posix)) + "%"
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).locale(posix)) + " s"
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(posix))
    }

    static func dollars(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(4)).locale(posix))
    }
}
