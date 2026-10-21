// A second module SwiftDemo imports: its types appear in SwiftDemo's
// signatures, and SwiftDemo extends them.

public struct Money {
    public var amount: Int
    public var currency: String

    public init(amount: Int, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    public func adding(_ other: Money) -> Money {
        Money(amount: amount + other.amount, currency: currency)
    }
}

public final class Wallet {
    public let owner: String
    public private(set) var balance: Money

    public init(owner: String) {
        self.owner = owner
        balance = Money(amount: 0, currency: "EUR")
    }

    public func deposit(_ money: Money) { balance = balance.adding(money) }
}

public enum Coin {
    case penny, dime
}

public func formatted(_ money: Money) -> String { "\(money.amount) \(money.currency)" }

// Generic types, bridged through the concrete instantiations declarations
// spell.

public struct Pair<First, Second> {
    public var first: First
    public var second: Second

    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }

    public func swapped() -> Pair<Second, First> { Pair<Second, First>(first: second, second: first) }
}

public final class Box<Value> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    public func replaced(with value: Value) -> Box<Value> { Box(value) }
    // On every instantiation, like WeatherKit's `WeatherQuery.daily`.
    public static var sample: Box<Int> { Box<Int>(7) }
}

public enum Outcome<Value> {
    case done(Value)
    case failed(reason: String)
}
