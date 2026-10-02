//
//  EvalRunner.swift
//  EvalKit
//

import AlbumAI
import Foundation

/// Runs each case through the real tool loop, with the canned library, several times.
public struct EvalRunner: Sendable {
    public var client: any MessageSending
    /// The requested model ID, for costing if a run fails before any response.
    public var model: String
    public var geocoder: any PlaceGeocoding
    public var runsPerCase: Int
    /// How many queries run at once.
    public var concurrency: Int

    public init(client: any MessageSending, model: String, geocoder: any PlaceGeocoding, runsPerCase: Int = 2, concurrency: Int = 4) {
        self.client = client
        self.model = model
        self.geocoder = geocoder
        self.runsPerCase = runsPerCase
        self.concurrency = max(1, concurrency)
    }

    /// Results in the order of `cases`. `progress` gets one line per finished run.
    public func run(_ cases: [ResolvedCase], progress: @Sendable @escaping (String) -> Void = { _ in }) async -> [CaseResult] {
        let jobs = cases.indices.flatMap { index in (0..<runsPerCase).map { (index, $0) } }
        var records = Array(repeating: [RunRecord?](repeating: nil, count: runsPerCase), count: cases.count)

        await withTaskGroup(of: (Int, Int, RunRecord).self) { group in
            var next = 0
            func addJob() {
                guard next < jobs.count else { return }
                let (index, attempt) = jobs[next]
                next += 1
                group.addTask { (index, attempt, await runOnce(cases[index])) }
            }
            for _ in 0..<concurrency {
                addJob()
            }
            for await (index, attempt, record) in group {
                records[index][attempt] = record
                let score = Scorer.score(cases[index], record)
                progress("\(score.passed ? "pass" : "FAIL") \(cases[index].id) #\(attempt + 1)"
                    + (score.problems.isEmpty ? "" : " · " + score.problems.joined(separator: "; ")))
                addJob()
            }
        }

        return cases.indices.map { index in
            CaseResult(testCase: cases[index], records: records[index].compactMap { $0 })
        }
    }

    /// One query through the full loop. Never throws: failures are part of the record.
    public func runOnce(_ testCase: ResolvedCase) async -> RunRecord {
        let tools = PhotoTools(library: CannedLibrary(), geocoder: geocoder, timeZone: testCase.timeZone)
        let loop = ToolLoop(client: client, tools: tools)
        let system = SearchPrompt.system(now: testCase.now, timeZone: testCase.timeZone)
        let collector = RoundCollector()
        let clock = ContinuousClock()
        let start = clock.now

        var presented: [String]?
        var errorText: String?
        var noAnswer = false
        do {
            let result = try await loop.run(testCase.query, system: system) { round in
                await collector.add(round)
            }
            presented = result.answer.photoIDs
        } catch {
            errorText = error.localizedDescription
            noAnswer = (error as? ToolLoopError) == .noAnswer
        }

        let rounds = await collector.rounds
        return RunRecord(
            calls: rounds.flatMap(\.toolCalls),
            presentedIDs: presented,
            error: errorText,
            endedWithNoAnswer: noAnswer,
            metrics: QueryMetrics(model: model, rounds: rounds, latency: start.duration(to: clock.now))
        )
    }
}

private actor RoundCollector {
    private(set) var rounds: [ToolLoopRound] = []
    func add(_ round: ToolLoopRound) { rounds.append(round) }
}

public struct CaseResult: Sendable {
    public enum Status: String, Sendable, Codable {
        case pass, fail
        /// Passed some runs and failed others: not a pass.
        case flaky
    }

    public var testCase: ResolvedCase
    public var records: [RunRecord]
    public var scores: [RunScore]

    public init(testCase: ResolvedCase, records: [RunRecord]) {
        self.testCase = testCase
        self.records = records
        scores = records.map { Scorer.score(testCase, $0) }
    }

    public var status: Status {
        if scores.allSatisfy(\.passed) { return .pass }
        if scores.contains(where: \.passed) { return .flaky }
        return .fail
    }
}
