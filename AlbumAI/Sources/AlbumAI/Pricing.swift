//
//  Pricing.swift
//  AlbumAI
//

import Foundation

/// Prices per million tokens for one model, in USD.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    /// 5-minute cache writes.
    public var cacheWrite: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public func cost(of usage: Usage) -> Double {
        (Double(usage.inputTokens) * input
            + Double(usage.outputTokens) * output
            + Double(usage.cacheCreationInputTokens) * cacheWrite
            + Double(usage.cacheReadInputTokens) * cacheRead) / 1_000_000
    }

    private enum CodingKeys: String, CodingKey {
        case input, output
        case cacheWrite = "cache_write"
        case cacheRead = "cache_read"
    }
}

/// The price table from `Resources/pricing.json`, copied from the official pricing page.
public struct PriceTable: Decodable, Sendable, Equatable {
    public var source: String
    public var checked: String
    public var models: [String: ModelPrice]

    public init(source: String = "", checked: String = "", models: [String: ModelPrice]) {
        self.source = source
        self.checked = checked
        self.models = models
    }

    /// The bundled table. A missing or broken file is a build mistake, so this traps.
    public static let bundled: PriceTable = {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(PriceTable.self, from: data)
        else {
            fatalError("pricing.json is missing or invalid")
        }
        return table
    }()

    /// The price for a model ID. Dated IDs match their alias:
    /// "claude-haiku-4-5-20251001" uses the "claude-haiku-4-5" row.
    public func price(for model: String) -> ModelPrice? {
        models
            .filter { model == $0.key || model.hasPrefix($0.key + "-") }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}

/// Rounds, latency, tokens and cost for one query, whether it succeeded or not.
public struct QueryMetrics: Sendable, Equatable {
    public var model: String
    public var rounds: Int
    public var latency: Duration
    public var usage: Usage
    /// Nil when the model isn't in the price table.
    public var cost: Double?

    public init(model: String, rounds: [ToolLoopRound], latency: Duration, prices: PriceTable = .bundled) {
        // The API reports the model on every response; fall back to the requested one.
        self.model = rounds.last?.model ?? model
        self.rounds = rounds.count
        self.latency = latency
        self.usage = rounds.map(\.usage).reduce(.zero, +)
        self.cost = prices.price(for: self.model)?.cost(of: usage)
    }

    /// One line for the console, e.g.
    /// `claude-haiku-4-5 · 3 rounds · 4.21 s · 3412 in / 287 out tokens · $0.004847 · ok, 3 photos`
    public func logLine(outcome: String) -> String {
        var tokens = "\(usage.inputTokens) in / \(usage.outputTokens) out tokens"
        if usage.cacheCreationInputTokens > 0 || usage.cacheReadInputTokens > 0 {
            tokens += " (cache: \(usage.cacheCreationInputTokens) written, \(usage.cacheReadInputTokens) read)"
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let seconds = (latency / .seconds(1)).formatted(.number.precision(.fractionLength(2)).locale(posix))
        let price = cost.map { "$" + $0.formatted(.number.precision(.fractionLength(6)).locale(posix)) } ?? "cost unknown"
        let roundsLabel = rounds == 1 ? "1 round" : "\(rounds) rounds"
        return "\(model) · \(roundsLabel) · \(seconds) s · \(tokens) · \(price) · \(outcome)"
    }
}
