// The Swift half of the interop benchmarks (SwiftInteropBenchmarks.js):
// TestFixtures' TNSBenchmark is the same API in Objective-C.

import CoreGraphics
import Foundation

public protocol BenchmarkDelegate: AnyObject {
    func value(for index: Int) -> Int
}

public struct BenchmarkRecord {
    public var name: String
    public var score: Double
    public var rank: Int
}

public struct BenchmarkPoint {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct BenchmarkFailure: Error {}

public final class Benchmark {
    public var counter = 0
    public init() {}

    public static func noop() {}
    public static func echoInt(_ value: Int) -> Int { value }
    public static func combine(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b + c }
    public static func negate(_ value: Bool) -> Bool { !value }
    public static func echoString(_ value: String) -> String { value }
    public static func length(of value: String) -> Int { value.utf16.count }
    public func increment() -> Int {
        counter += 1
        return counter
    }
    public static func sum(_ values: [Int]) -> Int { values.reduce(0, +) }
    public static func makeArray(_ count: Int) -> [Int] { Array(0..<count) }
    public static func sumValues(_ values: [String: Int]) -> Int { values.values.reduce(0, +) }
    public static func makeDictionary(_ count: Int) -> [String: Int] {
        var values: [String: Int] = [:]
        for i in 0..<count { values["key\(i)"] = i }
        return values
    }
    public static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    public static func midpointOf(_ a: BenchmarkPoint, _ b: BenchmarkPoint) -> BenchmarkPoint {
        BenchmarkPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    public static func makeData(_ length: Int) -> Data {
        var data = Data(count: length)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for i in 0..<length { buffer[i] = UInt8(truncatingIfNeeded: i) }
        }
        return data
    }
    public static func checksum(_ data: Data) -> Int {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in buffer.reduce(0) { $0 + Int($1) } }
    }
    public static func callClosure(_ body: (Int) -> Int, times count: Int) -> Int {
        var total = 0
        for i in 0..<count { total += body(i) }
        return total
    }
    public static func callDelegate(_ delegate: any BenchmarkDelegate, times count: Int) -> Int {
        var total = 0
        for i in 0..<count { total += delegate.value(for: i) }
        return total
    }
    public static func echoLater(_ value: Int) async -> Int { value }
    public static func fail() throws { throw BenchmarkFailure() }
    public static func topRecords(_ count: Int, minimumScore minimum: Double) -> [BenchmarkRecord] {
        var records: [BenchmarkRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let score = Double((i * 7919) % 1000) / 10.0
            if score < minimum { continue }
            records.append(BenchmarkRecord(name: "record \(i)", score: score, rank: 0))
        }
        records.sort { $0.score > $1.score }
        for i in records.indices { records[i].rank = i + 1 }
        return records
    }
}
