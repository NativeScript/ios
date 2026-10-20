import Foundation

public protocol Shape: Greeter {
    var area: Double { get }
    static var sides: Int { get }
}

open class Polygon {
    public let name: String
    public private(set) var vertexCount: Int
    public static let shared = Polygon(name: "shared", vertexCount: 0)

    public init(name: String, vertexCount: Int) {
        self.name = name
        self.vertexCount = vertexCount
    }

    public convenience init?(name: String) {
        guard !name.isEmpty else { return nil }
        self.init(name: name, vertexCount: 0)
    }

    open func scale(by factor: Double) {}
    open func scale(by factor: Int) {}
    public func scale(x: Double, y: Double) {}

    public class func make() -> Polygon { Polygon(name: "made", vertexCount: 3) }
    public static func describe(_ polygon: Polygon?) -> String { polygon?.name ?? "none" }

    public subscript(index: Int) -> Point { Point(x: Double(index), y: 0) }

    internal func hiddenHelper() {}
}

public final class Square: Polygon, Shape {
    public var side: Double

    public init(side: Double) {
        self.side = side
        super.init(name: "square", vertexCount: 4)
    }

    public var area: Double { side * side }
    public static var sides: Int { 4 }
    public func greet(name: String) -> String { "Square greets \(name)" }

    override public func scale(by factor: Double) { side *= factor }
}

public enum ShapeError: Error {
    case invalidSide(Double)
    case tooManySides(count: Int, limit: Int)
    case unknown
}

public enum Measurement {
    case length(Double)
    case area(width: Double, height: Double)
    case none

    public struct Unit {
        public var symbol: String
        public init(symbol: String) { self.symbol = symbol }
    }

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

public struct Ring {
    public var inner: Point
    public var outer: Point

    public init(inner: Point, outer: Point) {
        self.inner = inner
        self.outer = outer
    }

    public mutating func expand(by delta: Double) {
        outer.x += delta
        outer.y += delta
    }

    public static func + (lhs: Ring, rhs: Ring) -> Ring {
        Ring(inner: lhs.inner, outer: rhs.outer)
    }
}

public actor Counter {
    public private(set) var value: Int = 0
    public init() {}
    public func increment() -> Int {
        value += 1
        return value
    }
    public nonisolated func label() -> String { "counter" }
}

@MainActor
public final class Canvas {
    public init() {}
    public func draw(_ shape: any Shape) {}
}

public final class Loader {
    public init() {}

    public func load(path: String) throws -> Data { Data() }
    public func fetch(url: URL) async throws -> String { url.absoluteString }
    public func wait(seconds: Double) async {}

    public func transform<T: Shape>(_ shape: T) -> T { shape }
    public func first<Element>(of items: [Element]) -> Element? { items.first }

    public func withCompletion(_ completion: @escaping (Result<String, ShapeError>) -> Void) {}
    public func each(_ body: (Int) -> Void) {}

    public func lookup(table: [String: Int], key: String) -> Int? { table[key] }

    public func update(_ point: inout Point) { point.x += 1 }

    @available(iOS 16.0, *)
    public func modernOnly() {}

    @available(*, deprecated, message: "Use fetch(url:) instead")
    public func legacyFetch() {}

    @available(iOS, introduced: 15.0, deprecated: 17.0, renamed: "fetch(url:)")
    public func oldFetch() {}
}

public func makeDefaultPoint() -> Point { Point(x: 0, y: 0) }
public let defaultFlavor: Flavor = .vanilla
public var globalCounter: Int = 0
public typealias Coordinates = (latitude: Double, longitude: Double)
