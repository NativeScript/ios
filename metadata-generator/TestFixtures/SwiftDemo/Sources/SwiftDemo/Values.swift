// Declarations the runtime tests use to exercise value marshaling, errors and
// object lifetime.

import Foundation

public func checkedSide(_ side: Double) throws -> Double {
    if side < 0 { throw ShapeError.invalidSide(side) }
    return side
}

public func echoInt8(_ value: Int8) -> Int8 { value }
public func echoUInt64(_ value: UInt64) -> UInt64 { value }
public func largestInt() -> Int { Int.max }
public func shout(_ name: String?) -> String? { name.map { $0.uppercased() } }

public final class Tracker {
    public private(set) static var liveCount = 0
    public let id: Int

    public init(id: Int) {
        self.id = id
        Tracker.liveCount += 1
    }

    deinit { Tracker.liveCount -= 1 }

    public func same() -> Tracker { self }
}

public func delayedEcho(_ text: String, after seconds: Double) async throws -> String {
    if seconds < 0 { throw ShapeError.invalidSide(seconds) }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    return text
}

public func makeTrackerLater(id: Int) async -> Tracker {
    await Task.yield()
    return Tracker(id: id)
}

@MainActor
public final class Palette {
    public private(set) var strokes = 0
    public init() {}
    public func stroke() -> Int {
        strokes += 1
        return strokes
    }
    public func strokeLater() async -> Int {
        await Task.yield()
        return stroke()
    }
}

public func names(_ count: Int) -> [String] { (0..<count).map { "n\($0)" } }
public func total(_ values: [Double]) -> Double { values.reduce(0, +) }
public func centroid(of points: [Point]) -> Point { points.centroid() }
public func mirrored(_ grid: [[Int]]) -> [[Int]] { grid.map { Array($0.reversed()) } }
public func wordCounts(_ words: [String]) -> [String: Int] {
    words.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}
public func lengths(_ table: [String: String]) -> [String: Int] { table.mapValues { $0.count } }
public func trackers(_ ids: [Int]) -> [Tracker] { ids.map { Tracker(id: $0) } }
public func allFlavors() -> [Flavor] { [.vanilla, .chocolate] }
public func nextDay(after date: Date) -> Date { date.addingTimeInterval(86_400) }
public func host(of url: URL) -> String? { url.host }
public func resolve(_ path: String, against base: URL) -> URL { base.appendingPathComponent(path) }
public func checksum(_ data: Data) -> Int { data.reduce(0) { $0 + Int($1) } }
public func ramp(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 256) }) }
public func namesLater(_ count: Int) async -> [String] {
    await Task.yield()
    return names(count)
}

public func countdown(from start: Int, _ tick: (Int, Bool) -> Void) {
    for value in stride(from: start, through: 0, by: -1) {
        tick(value, value == 0)
    }
}

public func greetLater(_ name: String?, completion: @escaping @Sendable (String?) -> Void) {
    DispatchQueue.global().async {
        completion(name.map { "hi \($0)" })
    }
}

public final class Notifier: @unchecked Sendable {
    private var handlers: [@Sendable (String) -> Void] = []
    public init() {}
    public var count: Int { handlers.count }
    public func subscribe(_ handler: @escaping @Sendable (String) -> Void) { handlers.append(handler) }
    public func publish(_ message: String) { handlers.forEach { $0(message) } }
    public func publishLater(_ message: String) {
        let handlers = self.handlers
        DispatchQueue.global().async { handlers.forEach { $0(message) } }
    }
    public func clear() { handlers.removeAll() }
}

public func area(of measurement: Measurement) -> Double {
    switch measurement {
    case let .area(width, height): return width * height
    case .length, .none: return 0
    }
}

public func measure(_ width: Double, by height: Double?) -> Measurement {
    guard let height else { return width == 0 ? .none : .length(width) }
    return .area(width: width, height: height)
}

public func measurements() -> [Measurement] { [.length(1), .area(width: 2, height: 3), .none] }

public func measureLater(_ width: Double) async -> Measurement {
    await Task.yield()
    return .length(width)
}

public func onMeasure(_ body: (Measurement) -> Void) { body(.area(width: 1, height: 2)) }

public func explain(_ error: ShapeError) -> String {
    switch error {
    case let .invalidSide(side): return "invalid side \(side)"
    case let .tooManySides(count, limit): return "\(count) > \(limit)"
    case .unknown: return "unknown"
    }
}

public indirect enum Formula {
    case number(Double)
    case sum(Formula, Formula)
    case negate(Formula)

    public var value: Double {
        switch self {
        case let .number(value): return value
        case let .sum(a, b): return a.value + b.value
        case let .negate(formula): return -formula.value
        }
    }
}

public func simplify(_ formula: Formula) -> Formula { .number(formula.value) }

public enum Payload {
    case tracker(Tracker)
    case point(Point)
    case flavor(Flavor)
    case maybe(Int?)
    case names([String])
}

public func echo(_ payload: Payload) -> Payload { payload }

// Not bridged: a closure cannot be copied into a JS value.
public enum Job {
    case run(() -> Void)
    case idle

    public struct Ticket {
        public var id: Int
        public init(id: Int) { self.id = id }
    }
}

public func bump(_ value: inout Int) { value += 1 }
public func append(_ word: String, to words: inout [String]) { words.append(word) }
public func halve(_ value: inout Int) throws {
    guard value.isMultiple(of: 2) else { throw ShapeError.invalidSide(Double(value)) }
    value /= 2
}
public func clear(_ name: inout String?) { name = nil }
public func swapTrackers(_ a: inout Tracker, _ b: inout Tracker) { swap(&a, &b) }

// Counterparts of TNSPrimitives calls, for SwiftInteropBenchmarks.js.
public func echoInt(_ value: Int) -> Int { value }
public func echoString(_ value: String) -> String { value }

public final class Bench {
    public var value = 0
    public init() {}
    public static func echo(_ value: Int) -> Int { value }
    public func echo(_ value: Int) -> Int { value }
}

// Closures returning values (JS functions whose result Swift waits for).
public func transform(_ values: [Int], _ body: (Int) -> String) -> [String] { values.map(body) }
public func sortedNames(_ names: [String], by less: (String, String) -> Bool) -> [String] {
    names.sorted(by: less)
}
public func firstMatch(_ values: [Int], where predicate: (Int) throws -> Bool) throws -> Int? {
    try values.first(where: predicate)
}
public func lookup(_ key: String, _ resolve: (String) -> Int?) -> Int { resolve(key) ?? -1 }
public func computeInBackground(_ provider: @escaping @Sendable () -> Int) async -> Int {
    await Task.detached { provider() * 2 }.value
}

// Generic functions: one overload per stand-in for each type parameter.
public func largest<T: Comparable>(_ values: [T]) -> T? { values.max() }
public func repeated<T>(_ value: T, times: Int) -> [T] { Array(repeating: value, count: times) }
public func popCount<I: FixedWidthInteger>(_ value: I) -> Int { value.nonzeroBitCount }
public func zero<N: Numeric>() -> N { 0 }
public func greetTwice<G: Greeting>(_ greeting: G, _ other: String) -> String {
    greeting.greet(other) + " " + greeting.greet(other)
}
// Not instantiated: a metatype, an associated type, and too many
// combinations.
public func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(text.utf8))
}
public func firstElement<C: Collection>(_ values: C) -> C.Element? { values.first }
public func joined<A, B>(_ first: A, _ second: B) -> String { "\(first)/\(second)" }

// Optional collection elements (JS nulls).
public func compact(_ values: [Int?]) -> [Int] { values.compactMap { $0 } }
public func holes(_ count: Int) -> [String?] { (0..<count).map { $0 % 2 == 0 ? "x" : nil } }
public func knownScores(_ scores: [String: Int?]) -> [String: Int?] { scores.filter { $0.value != nil } }

// Tuples (JS arrays, or objects when labeled) and sets (JS Sets).
public func divide(_ a: Int, by b: Int) -> (quotient: Int, remainder: Int) { (a / b, a % b) }
public func swapPair(_ pair: (Int, String)) -> (String, Int) { (pair.1, pair.0) }
public func plot(_ point: (x: Double, y: Double)?) -> String? { point.map { "\($0.x),\($0.y)" } }
public func spans() -> [(String, Int?)] { [("a", 1), ("b", nil)] }
public func uniqueTags(_ tags: [String]) -> Set<String> { Set(tags) }
public func countUnique(_ values: Set<Int>) -> Int { values.count }
public func tallyLater(_ words: [String]) async -> (unique: Set<String>, count: Int) {
    (Set(words), words.count)
}

// Errors as values, and Result (tagged objects naming their case).
public struct ParseFailure: Error, CustomStringConvertible {
    public let text: String
    public var description: String { "not a number: \(text)" }
}
public func parseNumber(_ text: String) -> Result<Int, any Error> {
    if let value = Int(text) { return .success(value) }
    return .failure(ParseFailure(text: text))
}
public func checkSides(_ sides: Int) -> Result<Void, ShapeError> {
    sides >= 3 ? .success(()) : .failure(.tooManySides(count: sides, limit: 3))
}
public func unwrap(_ result: Result<String, any Error>) throws -> String { try result.get() }
public func parseLater(_ text: String) async -> Result<Int, any Error> { parseNumber(text) }
public func fetchItem(_ id: Int, _ completion: @escaping @Sendable (Result<String, any Error>) -> Void) {
    DispatchQueue.global().async {
        completion(id > 0 ? .success("item \(id)") : .failure(ParseFailure(text: "\(id)")))
    }
}
public func describeError(_ error: (any Error)?) -> String { error.map { "\($0)" } ?? "none" }

// `some P` parameters: implicit generic parameters, instantiated the same way.
public func shoutAll(_ value: some StringProtocol) -> String { value.uppercased() }
public func describeValue(_ value: some CustomStringConvertible) -> String { value.description }
public func greetOnce(_ greeting: some Greeting, _ other: String) -> String { greeting.greet(other) }

// Cancellation: an AbortSignal after the arguments cancels the Swift task.
public final class CancelLog {
    public static var cancellations = 0
}
public func waitForCancel(_ seconds: Double) async -> Bool {
    do {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return false
    } catch {
        CancelLog.cancellations += 1
        return true
    }
}

// Subscripts: `subscript(...)` and `setSubscript(..., value)` in JS.
public final class Shelf {
    private var counts: [String: Int] = [:]
    public init() {}
    public subscript(name: String) -> Int? {
        get { counts[name] }
        set { counts[name] = newValue }
    }
    public subscript(row: Int, column: Int) -> String { "\(row),\(column)" }
}
public struct Grid {
    public var cells: [Int]
    public init(size: Int) { cells = Array(repeating: 0, count: size) }
    public subscript(index: Int) -> Int {
        get { cells[index] }
        set { cells[index] = newValue }
    }
}
