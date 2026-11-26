extension Demo {
    public func greet(name: String, times: Int) -> String {
        String(repeating: greet(name: name), count: times)
    }

    public static var version: String { "1.0" }
}

extension Point: CustomStringConvertible {
    public var description: String { "(\(x), \(y))" }
    public var length: Double { (x * x + y * y).squareRoot() }
}

extension Flavor: CustomStringConvertible {
    public var description: String { self == .vanilla ? "vanilla" : "chocolate" }
}

extension String {
    public var shouted: String { uppercased() + "!" }
}

extension Array where Element == Point {
    public func centroid() -> Point {
        guard !isEmpty else { return Point(x: 0, y: 0) }
        let sx = reduce(0) { $0 + $1.x }
        let sy = reduce(0) { $0 + $1.y }
        return Point(x: sx / Double(count), y: sy / Double(count))
    }
}
