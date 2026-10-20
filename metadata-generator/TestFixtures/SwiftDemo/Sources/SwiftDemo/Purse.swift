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
