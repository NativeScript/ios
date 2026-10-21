// Asynchronous sequences, which JavaScript iterates with `for await`.

import Combine
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

// Types conforming to AsyncSequence: JS iterates them with `for await` and
// still reaches their other members.
public struct Countdown: AsyncSequence {
    public typealias Element = Int
    public let start: Int
    public init(from start: Int) { self.start = start }
    public var label: String { "countdown from \(start)" }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var current: Int
        public mutating func next() async -> Int? {
            guard current > 0 else { return nil }
            defer { current -= 1 }
            return current
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(current: start) }
}

// Element inferred from the iterator's next().
public final class WordStream: AsyncSequence {
    private let words: [String]
    public init(_ text: String) { words = text.split(separator: " ").map(String.init) }

    public struct Iterator: AsyncIteratorProtocol {
        var words: ArraySlice<String>
        public mutating func next() async throws -> String? { words.popFirst() }
    }
    public func makeAsyncIterator() -> Iterator { Iterator(words: words[...]) }
}

// Combine publishers: async sequences of their output (iOS 15+).
public final class Thermometer {
    private let subject = PassthroughSubject<Double, Never>()
    public init() {}
    public var readings: AnyPublisher<Double, Never> { subject.eraseToAnyPublisher() }
    public func record(_ value: Double) { subject.send(value) }
    public func finish() { subject.send(completion: .finished) }
}

// An endless stream: `break` in JS ends it (onTermination sees the end).
public final class StreamLog {
    public static var terminations = 0
}
public func ticker() -> AsyncStream<Int> {
    AsyncStream { continuation in
        continuation.onTermination = { _ in StreamLog.terminations += 1 }
        Task {
            var tick = 0
            while true {
                tick += 1
                if case .terminated = continuation.yield(tick) { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }
}
