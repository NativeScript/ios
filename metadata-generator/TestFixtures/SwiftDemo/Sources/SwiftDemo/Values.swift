// Declarations the runtime tests use to exercise value marshaling, errors and
// object lifetime.

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
