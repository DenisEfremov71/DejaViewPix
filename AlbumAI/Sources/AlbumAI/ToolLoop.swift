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
        - Always finish by calling present_results, even when nothing matched. Its photo_ids must \
        be copied from search_photos results.
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
    /// The final answer failed validation twice. The message is the second failure.
    case invalidAnswer(String)
    /// Claude ended its turn twice without calling present_results.
    case noAnswer

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
        case .invalidAnswer(let message):
            "Claude's answer was still invalid after one correction. \(message)"
        case .noAnswer:
            "Claude finished without presenting any results."
        }
    }
}

/// One tool call and what went back to Claude.
public struct ToolCallRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var output: ToolOutput

    public init(id: String, name: String, input: JSONValue, output: ToolOutput) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
    }
}

/// One request/response round trip.
public struct ToolLoopRound: Sendable, Equatable {
    public var number: Int
    /// The model that answered, as reported by the API.
    public var model: String?
    public var stopReason: String?
    public var usage: Usage
    public var latency: Duration
    /// The text Claude wrote alongside its tool calls, if any.
    public var text: String
    /// Every tool call in this round, present_results included.
    public var toolCalls: [ToolCallRecord]
}

public struct ToolLoopResult: Sendable, Equatable {
    public var answer: SearchAnswer
    public var rounds: [ToolLoopRound]
    /// The whole conversation, ending with the present_results call.
    public var messages: [Message]

    public var usage: Usage {
        rounds.map(\.usage).reduce(.zero, +)
    }
}

/// Runs the tool-calling loop: send the conversation, run the tools Claude asks for, send
/// the results back, and repeat until Claude presents a valid answer or `maxRounds` requests
/// are spent. One bad ending (an invalid answer, or no answer) gets a correction; a second
/// one fails the search.
public struct ToolLoop: Sendable {
    public let client: any MessageSending
    public let tools: any ToolExecuting
    public let maxRounds: Int

    public init(client: any MessageSending, tools: any ToolExecuting, maxRounds: Int = 5) {
        self.client = client
        self.tools = tools
        self.maxRounds = maxRounds
    }

    /// - Parameter onRound: Called after each round, including the last one before an error,
    ///   so callers can log usage for failed searches too.
    public func run(
        _ query: String,
        system: String,
        onRound: @Sendable (ToolLoopRound) async -> Void = { _ in }
    ) async throws -> ToolLoopResult {
        var messages: [Message] = [.user(query)]
        var rounds: [ToolLoopRound] = []
        var calls: [ToolCallRecord] = []
        var correctionUsed = false
        let definitions = tools.definitions + [SearchAnswer.toolDefinition]
        let clock = ContinuousClock()

        for number in 1...maxRounds {
            let start = clock.now
            let response = try await client.createMessage(system: system, messages: messages, tools: definitions)
            let latency = start.duration(to: clock.now)

            // The assistant turn goes back exactly as received, tool_use blocks included.
            messages.append(Message(role: .assistant, content: response.content))

            var round = ToolLoopRound(
                number: number,
                model: response.model,
                stopReason: response.stopReason,
                usage: response.usage,
                latency: latency,
                text: response.text,
                toolCalls: []
            )

            switch response.stopReason {
            case "tool_use" where !response.toolUses.isEmpty:
                break

            case "end_turn", "stop_sequence":
                // Claude answered in prose instead of calling present_results.
                rounds.append(round)
                await onRound(round)
                if correctionUsed {
                    throw ToolLoopError.noAnswer
                }
                correctionUsed = true
                messages.append(.user(
                    "Please call present_results with your answer. Use an empty photo_ids list if nothing matched."
                ))
                continue

            default:
                rounds.append(round)
                await onRound(round)
                throw ToolLoopError.unexpectedStop(response.stopReason)
            }

            // One tool_result per tool_use, in the same order, all in one user message.
            var results: [ContentBlock] = []
            for call in response.toolUses {
                let output: ToolOutput
                if call.name == SearchAnswer.toolName {
                    guard response.toolUses.count == 1 else {
                        output = ToolOutput(
                            content: "Call present_results on its own, after the other tools have returned.",
                            isError: true
                        )
                        round.toolCalls.append(ToolCallRecord(id: call.id, name: call.name, input: call.input, output: output))
                        results.append(.toolResult(toolUseID: call.id, content: output.content, isError: true))
                        continue
                    }
                    do {
                        let answer = try SearchAnswer.validated(input: call.input, calls: calls)
                        round.toolCalls.append(ToolCallRecord(
                            id: call.id, name: call.name, input: call.input,
                            output: ToolOutput(content: "OK", photoIDs: answer.photoIDs)
                        ))
                        rounds.append(round)
                        await onRound(round)
                        return ToolLoopResult(answer: answer, rounds: rounds, messages: messages)
                    } catch {
                        let message = error.localizedDescription
                        if correctionUsed {
                            round.toolCalls.append(ToolCallRecord(
                                id: call.id, name: call.name, input: call.input,
                                output: ToolOutput(content: message, isError: true)
                            ))
                            rounds.append(round)
                            await onRound(round)
                            throw ToolLoopError.invalidAnswer(message)
                        }
                        correctionUsed = true
                        output = ToolOutput(content: message, isError: true)
                    }
                } else {
                    output = try await execute(name: call.name, input: call.input)
                }

                let record = ToolCallRecord(id: call.id, name: call.name, input: call.input, output: output)
                round.toolCalls.append(record)
                calls.append(record)
                results.append(.toolResult(toolUseID: call.id, content: output.content, isError: output.isError))
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
