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
