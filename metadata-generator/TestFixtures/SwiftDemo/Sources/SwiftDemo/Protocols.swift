// Protocols JavaScript objects can implement.

public protocol Greeting: AnyObject {
    var name: String { get }
    var punctuation: String { get set }
    func greet(_ other: String) -> String
    func reset()
}

public protocol Scorer {
    func score(_ value: Int) throws -> Int
}

// Refines Scorer: implementations provide both protocols' requirements.
public protocol RankedScorer: Scorer {
    var rank: Int? { get }
}

extension Greeting {
    public func shout(_ other: String) -> String { greet(other).uppercased() }
}

public final class FormalGreeting: Greeting {
    public let name: String
    public var punctuation = "."
    public init(name: String) { self.name = name }
    public func greet(_ other: String) -> String { "Good day, \(other), from \(name)" }
    public func reset() { punctuation = "." }
}

public struct DoublingScorer: Scorer {
    public init() {}
    public func score(_ value: Int) -> Int { value * 2 }
}

public func introduce(_ greeting: any Greeting, to other: String) -> String {
    greeting.greet(other) + greeting.punctuation
}

public func makeGreeting(_ name: String) -> any Greeting { FormalGreeting(name: name) }
public func same(_ greeting: any Greeting) -> any Greeting { greeting }
public func excite(_ greeting: any Greeting) { greeting.punctuation = "!" }
public func scoreAll(_ scorer: any Scorer, _ values: [Int]) throws -> [Int] {
    try values.map { try scorer.score($0) }
}
public func makeScorer() -> any Scorer { DoublingScorer() }
public func topRank(_ scorer: any RankedScorer) throws -> String {
    "\(scorer.rank ?? -1):\(try scorer.score(1))"
}

private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public func greetInBackground(_ greeting: any Greeting) async -> String {
    let box = Unchecked(greeting)
    return await Task.detached { box.value.greet("background") }.value
}

public final class GreetingHolder {
    public var greeting: (any Greeting)?
    public init() {}
    public func greet(_ other: String) -> String? { greeting?.greet(other) }
}
