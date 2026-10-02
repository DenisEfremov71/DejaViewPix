//
//  ToolLoop.swift
//  AlbumAI
//

import Foundation

public enum SearchPrompt {
    /// The system prompt. `now` and `timeZone` are injected so tests and evals get the same
    /// "today" every run.
    public static func system(now: Date, timeZone: TimeZone) -> String {
        """
        You help the user find photos in their own photo library. Use the tools to search; \
        never invent photo IDs.

        \(todayLine(now: now, timeZone: timeZone))
        Resolve relative dates against this date. Seasons follow the northern hemisphere \
        unless the place is in the southern one: winter is December through February. "Last \
        winter" means the most recent winter that has already ended. "Last year" means the \
        previous calendar year.

        - When the user names a place, call geocode_place first, then pass its latitude, \
        longitude and radius_meters to search_photos.
        - When the user names an album, call list_albums unless you already know its exact title.
        - Only set filters the user asked for. Don't add a location, date or media type they didn't mention.
        - If a search finds nothing, you may retry once with a wider date range or radius, and say so.
        - Finish with one or two short sentences saying what you found. Don't list photo IDs; \
        the app shows the photos.
        """
    }

    /// "Today is 2026-10-02 (Friday), time zone America/Vancouver."
    public static func todayLine(now: Date, timeZone: TimeZone) -> String {
        let format = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) (\(weekday: .wide))",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
        return "Today is \(now.formatted(format)), time zone \(timeZone.identifier)."
    }
}

public enum ToolLoopError: LocalizedError, Sendable, Equatable {
    /// Claude still wanted tools after the last allowed round.
    case roundLimitReached(Int)
    /// The reply stopped for a reason other than `end_turn` or `tool_use`.
    case unexpectedStop(String?)

    public var errorDescription: String? {
        switch self {
        case .roundLimitReached(let rounds):
            "The search didn't finish within \(rounds) rounds of tool calls."
        case .unexpectedStop("refusal"):
            "Claude declined this request."
        case .unexpectedStop("max_tokens"):
            "The reply hit the max_tokens limit before it finished."
        case .unexpectedStop(let reason):
            "The reply stopped unexpectedly (stop reason: \(reason ?? "none"))."
        }
    }
}

/// One tool call and what went back to Claude.
public struct ToolCallRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var output: ToolOutput
}

/// One request/response round trip.
public struct ToolLoopRound: Sendable, Equatable {
    public var number: Int
    public var stopReason: String?
    public var usage: Usage
    public var latency: Duration
    /// The text Claude wrote alongside its tool calls, if any.
    public var text: String
    public var toolCalls: [ToolCallRecord]
}

public struct ToolLoopResult: Sendable, Equatable {
    public var finalText: String
    public var rounds: [ToolLoopRound]
    /// The whole conversation, ending with Claude's final message.
    public var messages: [Message]

    /// Photo IDs from every successful search, without duplicates, in the order returned.
    public var photoIDs: [String] {
        var seen = Set<String>()
        return rounds
            .flatMap(\.toolCalls)
            .filter { !$0.output.isError }
            .flatMap(\.output.photoIDs)
            .filter { seen.insert($0).inserted }
    }

    public var usage: Usage {
        Usage(
            inputTokens: rounds.map(\.usage.inputTokens).reduce(0, +),
            outputTokens: rounds.map(\.usage.outputTokens).reduce(0, +)
        )
    }
}

/// Runs the tool-calling loop: send the conversation, run the tools Claude asks for, send
/// the results back, and repeat until Claude ends its turn or `maxRounds` requests are spent.
public struct ToolLoop: Sendable {
    public let client: any MessageSending
    public let tools: any ToolExecuting
    public let maxRounds: Int

    public init(client: any MessageSending, tools: any ToolExecuting, maxRounds: Int = 5) {
        self.client = client
        self.tools = tools
        self.maxRounds = maxRounds
    }

    /// - Parameter onRound: Called after each round, e.g. to show progress.
    public func run(
        _ query: String,
        system: String,
        onRound: @Sendable (ToolLoopRound) async -> Void = { _ in }
    ) async throws -> ToolLoopResult {
        var messages: [Message] = [.user(query)]
        var rounds: [ToolLoopRound] = []
        let clock = ContinuousClock()

        for number in 1...maxRounds {
            let start = clock.now
            let response = try await client.createMessage(
                system: system,
                messages: messages,
                tools: tools.definitions
            )
            let latency = start.duration(to: clock.now)

            // The assistant turn goes back exactly as received, tool_use blocks included.
            messages.append(Message(role: .assistant, content: response.content))

            var round = ToolLoopRound(
                number: number,
                stopReason: response.stopReason,
                usage: response.usage,
                latency: latency,
                text: response.text,
                toolCalls: []
            )

            switch response.stopReason {
            case "end_turn", "stop_sequence":
                rounds.append(round)
                await onRound(round)
                return ToolLoopResult(finalText: response.text, rounds: rounds, messages: messages)
            case "tool_use" where !response.toolUses.isEmpty:
                break
            default:
                throw ToolLoopError.unexpectedStop(response.stopReason)
            }

            // One tool_result per tool_use, in the same order, all in one user message.
            var results: [ContentBlock] = []
            for call in response.toolUses {
                let output = try await execute(name: call.name, input: call.input)
                results.append(.toolResult(toolUseID: call.id, content: output.content, isError: output.isError))
                round.toolCalls.append(ToolCallRecord(id: call.id, name: call.name, input: call.input, output: output))
            }
            messages.append(Message(role: .user, content: results))

            rounds.append(round)
            await onRound(round)
        }

        throw ToolLoopError.roundLimitReached(maxRounds)
    }

    /// Runs one tool. A failure becomes an error result for Claude instead of ending the loop;
    /// only cancellation propagates.
    private func execute(name: String, input: JSONValue) async throws -> ToolOutput {
        do {
            return try await tools.execute(name: name, input: input)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return ToolOutput(content: error.localizedDescription, isError: true)
        }
    }
}
