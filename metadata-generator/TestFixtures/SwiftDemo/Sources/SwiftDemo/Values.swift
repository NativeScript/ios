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
