// Objective-C classes in Swift signatures, which cross as NativeScript's
// ordinary Objective-C wrappers.

import CoreLocation
import UIKit

public func describe(_ view: UIView) -> String { "\(type(of: view)) \(view.tag)" }

@MainActor public func makeLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    return label
}

public func tags(_ views: [UIView]) -> [Int] { views.map(\.tag) }

public func firstSubview(of view: UIView) -> UIView? { view.subviews.first }

public final class Note: NSObject {
    public let text: String
    public init(text: String) { self.text = text }

    // Swift-only members, installed on NativeScript's Note class.
    public var tags: Set<String> = []
    public func tagged(_ tag: String) -> Note {
        tags.insert(tag)
        return self
    }
    public func summary(maxLength: Int) -> String { String(text.prefix(maxLength)) }
    public static func blank() -> Note { Note(text: "") }
    // Objective-C-visible: NativeScript's own.
    @objc public var revision = 1
}

// A view written in Swift with a Swift-typed API.
public final class CounterView: UIView {
    public private(set) var count = 0
    public func configure(start: Int, step: Int?) -> Int {
        count = start + (step ?? 1)
        return count
    }
}

public func makeNote(_ text: String) -> Note { Note(text: text) }
public func text(of note: Note) -> String { note.text }

public func noteLater(_ text: String) async -> Note {
    await Task.yield()
    return Note(text: text)
}

public func viewTag<V: UIView>(_ view: V) -> Int { view.tag }

// C structs with known fields (plain JS objects).
public func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}
public func inset(_ rect: CGRect, by insets: UIEdgeInsets) -> CGRect { rect.inset(by: insets) }
public func fitting(_ size: CGSize?) -> CGSize? { size.map { CGSize(width: $0.width * 2, height: $0.height * 2) } }
public func latitudeSpan(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    abs(a.latitude - b.latitude)
}
public func tagOf(_ view: some UIView) -> Int { view.tag }
