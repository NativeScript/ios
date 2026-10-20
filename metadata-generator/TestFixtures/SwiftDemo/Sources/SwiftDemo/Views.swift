// Objective-C classes in Swift signatures, which cross as NativeScript's
// ordinary Objective-C wrappers.

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
}

public func makeNote(_ text: String) -> Note { Note(text: text) }
public func text(of note: Note) -> String { note.text }

public func noteLater(_ text: String) async -> Note {
    await Task.yield()
    return Note(text: text)
}
