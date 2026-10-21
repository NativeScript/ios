// An @Observable class JavaScript can track.

import Foundation
import Observation

@available(iOS 17.0, *)
@Observable public final class Thermostat {
    public var celsius: Double = 20
    public var label = "home"

    public init() {}

    public func warm(by delta: Double) { celsius += delta }

    public func warmLater(by delta: Double) {
        let target = Unchecked(self)
        DispatchQueue.global().async { target.value.celsius += delta }
    }
}
