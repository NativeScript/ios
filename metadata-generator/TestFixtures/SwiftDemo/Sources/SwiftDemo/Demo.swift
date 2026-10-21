public protocol Greeter {
    func greet(name: String) -> String
}

public class Demo: Greeter {
    public init() {}
    public func greet(name: String) -> String { "Hello, \(name)" }
}

public struct Point {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum Flavor: Int { case vanilla = 0, chocolate = 1 }
