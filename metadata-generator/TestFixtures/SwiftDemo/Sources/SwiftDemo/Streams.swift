// Asynchronous sequences, which JavaScript iterates with `for await`.

import Foundation

public func countUp(to limit: Int) -> AsyncStream<Int> {
    AsyncStream { continuation in
        for value in 0..<limit {
            continuation.yield(value + 1)
        }
        continuation.finish()
    }
}

public struct CountdownError: Error {}

public func countDown(from start: Int, failingAt failure: Int?) -> AsyncThrowingStream<Int, any Error> {
    AsyncThrowingStream { continuation in
        Task {
            for value in stride(from: start, through: 0, by: -1) {
                if value == failure {
                    continuation.finish(throwing: CountdownError())
                    return
                }
                continuation.yield(value)
                await Task.yield()
            }
            continuation.finish()
        }
    }
}

@available(iOS 18.0, *)
public func letters(of word: String) -> some AsyncSequence<String, Never> {
    AsyncStream { continuation in
        for character in word {
            continuation.yield(String(character))
        }
        continuation.finish()
    }
}

public func pages(_ count: Int) -> AsyncStream<[String]> {
    AsyncStream { continuation in
        for page in 0..<count {
            continuation.yield(["page \(page)", "item"])
        }
        continuation.finish()
    }
}
