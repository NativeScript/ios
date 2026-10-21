// Declarations using and extending SwiftDemoKit's types.

import SwiftDemoKit

public func starterWallet(for owner: String) -> Wallet {
    let wallet = Wallet(owner: owner)
    wallet.deposit(Money(amount: 5, currency: "EUR"))
    return wallet
}

public func sum(of amounts: [Money]) -> Money {
    amounts.reduce(Money(amount: 0, currency: "EUR")) { $0.adding($1) }
}

public func flip(_ coin: Coin) -> Coin { coin == .penny ? .dime : .penny }

extension Money {
    public var isZero: Bool { amount == 0 }
    public func doubled() -> Money { adding(self) }
}

extension Wallet {
    public func summary() -> String { "\(owner): \(formatted(balance))" }
}

public typealias Score = Pair<String, Int>

public func makeScore(_ name: String, _ points: Int) -> Score { Score(first: name, second: points) }
public func describe(_ pair: Pair<Int, String>) -> String { "\(pair.first):\(pair.second)" }
public func boxed(_ money: Money) -> Box<Money> { Box(money) }
public func countBox(_ value: Int) -> Box<Int> { Box(value) }
public func settle(_ value: Int) -> Outcome<Int> { value >= 0 ? .done(value) : .failed(reason: "negative") }

// Generic functions over the unit's generic types: instantiated with the
// arguments of Box's and Pair's instantiations.
public func unbox<T>(_ box: Box<T>) -> T { box.value }
public func firstOf<A, B>(_ pair: Pair<A, B>) -> A { pair.first }
