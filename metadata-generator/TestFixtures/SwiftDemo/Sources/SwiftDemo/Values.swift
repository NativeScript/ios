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
