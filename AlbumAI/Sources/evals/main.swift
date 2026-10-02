//
//  main.swift
//  evals
//
//  swift run evals [--model haiku|sonnet|opus] [--runs 2] [--split dev|test|all]
//                  [--case ID]... [--concurrency 4] [--no-save]
//
//  Scores the search against evals/cases.json with the real API and the canned library.
//  Reads the key from ANTHROPIC_API_KEY. Costs money: about $0.008 per run on Haiku.
//

import AlbumAI
import CryptoKit
import EvalKit
import Foundation

struct Options {
    var model = ClaudeModel.haiku
    var runs = 2
    var splits: Set<Split> = [.dev]
    var caseIDs: Set<String> = []
    var concurrency = 4
    var save = true

    static let usage = """
        usage: swift run evals [--model haiku|sonnet|opus] [--runs N] [--split dev|test|all]
                               [--case ID]... [--concurrency N] [--no-save]
        The held-back test split runs only with --split test or all.
        """

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        func value(for flag: String) throws -> String {
            guard let value = iterator.next() else { throw OptionError("\(flag) needs a value") }
            return value
        }
        while let argument = iterator.next() {
            switch argument {
            case "--model":
                switch try value(for: argument) {
                case "haiku": model = .haiku
                case "sonnet": model = .sonnet
                case "opus": model = .opus
                case let other: throw OptionError("unknown model \(other)")
                }
            case "--runs":
                guard let runs = Int(try value(for: argument)), runs > 0 else { throw OptionError("--runs needs a positive number") }
                self.runs = runs
            case "--split":
                switch try value(for: argument) {
                case "dev": splits = [.dev]
                case "test": splits = [.test]
                case "all": splits = [.dev, .test]
                case let other: throw OptionError("unknown split \(other)")
                }
            case "--case":
                caseIDs.insert(try value(for: argument))
            case "--concurrency":
                guard let concurrency = Int(try value(for: argument)), concurrency > 0 else {
                    throw OptionError("--concurrency needs a positive number")
                }
                self.concurrency = concurrency
            case "--no-save":
                save = false
            case "--help", "-h":
                throw OptionError(nil)
            default:
                throw OptionError("unknown option \(argument)")
            }
        }
    }
}

struct OptionError: Error {
    var message: String?
    init(_ message: String?) { self.message = message }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// The repository root: the first directory up from here that has evals/cases.json.
func repositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        if FileManager.default.fileExists(atPath: directory.appending(path: "evals/cases.json").path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
}

/// Changes whenever the system prompt or a tool definition changes, so results from
/// different prompt versions are never compared by accident.
func promptFingerprint() throws -> String {
    let system = SearchPrompt.system(now: Date(timeIntervalSince1970: 0), timeZone: .gmt)
    let tools = PhotoTools(library: CannedLibrary(), geocoder: PlaceGeocoder(), timeZone: .gmt).definitions
        + [SearchAnswer.toolDefinition]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var data = Data(system.utf8)
    data.append(try encoder.encode(tools))
    return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
}

let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch let error as OptionError {
    if let message = error.message { printError("evals: \(message)") }
    printError(Options.usage)
    exit(error.message == nil ? 0 : 2)
}

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
    printError("evals: set ANTHROPIC_API_KEY. The evals never read the app's Keychain.")
    exit(2)
}
guard let root = repositoryRoot() else {
    printError("evals: can't find evals/cases.json in this directory or any parent.")
    exit(2)
}

let allCases = try Dataset.load(from: root.appending(path: "evals/cases.json")).resolved()
let cases = allCases.filter { options.splits.contains($0.split) && (options.caseIDs.isEmpty || options.caseIDs.contains($0.id)) }
guard !cases.isEmpty else {
    printError("evals: no cases match.")
    exit(2)
}
if !options.caseIDs.isEmpty, let unknown = options.caseIDs.subtracting(allCases.map(\.id)).first {
    printError("evals: no case \(unknown).")
    exit(2)
}

let fingerprint = try promptFingerprint()
let geocoder = CachingGeocoder(PlaceGeocoder())
let runner = EvalRunner(
    client: ClaudeClient(model: options.model, apiKey: { apiKey }),
    model: options.model.rawValue,
    geocoder: geocoder,
    runsPerCase: options.runs,
    concurrency: options.concurrency
)

printError("Running \(cases.count) cases × \(options.runs) on \(options.model.rawValue), prompt \(fingerprint)…")
let results = await runner.run(cases) { line in printError(line) }
let report = Report(
    results: results,
    model: options.model.rawValue,
    promptFingerprint: fingerprint,
    runsPerCase: options.runs,
    geocodes: await geocoder.lookups
)
let markdown = report.markdown()
print(markdown)

if options.save {
    let directory = root.appending(path: "evals/results")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = Date.now.formatted(.verbatim(
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    ))
    let alias = switch options.model {
    case .haiku: "haiku"
    case .sonnet: "sonnet"
    case .opus: "opus"
    case .nonexisting: "invalid"
    }
    let split = options.splits.count == 2 ? "all" : options.splits.first!.rawValue
    let base = directory.appending(path: "\(stamp)-\(alias)-\(split)")
    try report.json().write(to: base.appendingPathExtension("json"))
    try Data(markdown.utf8).write(to: base.appendingPathExtension("md"))
    printError("Saved \(base.lastPathComponent).json and .md in evals/results/")
}
