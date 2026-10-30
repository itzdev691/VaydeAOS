import Foundation

/// A damped spring follows the drag target, then releases with its existing velocity.
/// Sampling is analytic, so motion does not depend on the render or pointer event rate.
public struct ConnectionMotion {
    public struct Position {
        public let rotation: Double
        public let tilt: Double
    }

    private var rotation = 0.4
    private var tilt = -0.19
    private var yawVelocity = 0.055
    private var tiltVelocity = 0.0
    private var targetRotation = 0.4
    private var targetTilt = -0.19
    private var dragging = false
    private var epoch: TimeInterval
    private var advancing = false
    private static let drift = 0.055
    private static let damping = 0.7
    private static let springFrequency = 14.0

    public init(at time: TimeInterval) { epoch = time }

    public func position(at time: TimeInterval) -> Position {
        let state = state(at: time)
        return Position(rotation: state.rotation, tilt: state.tilt)
    }

    public mutating func setAdvancing(_ active: Bool, at time: TimeInterval) {
        guard active != advancing else { return }
        settle(at: time)
        advancing = active
    }

    public mutating func drag(rotation delta: Double, tilt tiltDelta: Double, at time: TimeInterval) {
        settle(at: time)
        if !dragging {
            targetRotation = rotation
            targetTilt = tilt
            dragging = true
        }
        targetRotation += delta.isFinite ? delta : 0
        targetTilt = Self.clampTilt(targetTilt + (tiltDelta.isFinite ? tiltDelta : 0))
        // Paused and reduced-motion interaction follows the pointer without an animated tail.
        if !advancing {
            rotation = targetRotation
            tilt = targetTilt
            yawVelocity = 0
            tiltVelocity = 0
        }
    }

    public mutating func endDrag(at time: TimeInterval) {
        guard dragging else { return }
        settle(at: time)
        dragging = false
    }

    private struct State {
        var rotation: Double
        var tilt: Double
        var yawVelocity: Double
        var tiltVelocity: Double
    }

    private func state(at time: TimeInterval) -> State {
        let elapsed = advancing ? max(0, time - epoch) : 0
        let yaw: (position: Double, velocity: Double)
        let pitch: (position: Double, velocity: Double)
        if dragging {
            yaw = Self.spring(position: rotation, velocity: yawVelocity, target: targetRotation, elapsed: elapsed)
            pitch = Self.spring(position: tilt, velocity: tiltVelocity, target: targetTilt, elapsed: elapsed)
        } else {
            let decay = exp(-Self.damping * elapsed)
            let travel = -expm1(-Self.damping * elapsed) / Self.damping
            yaw = (rotation + Self.drift * elapsed + (yawVelocity - Self.drift) * travel,
                   Self.drift + (yawVelocity - Self.drift) * decay)
            // Increase drag near the tilt boundary instead of coasting into a hard stop.
            // The initial velocity is unchanged; the remaining travel approaches the
            // boundary asymptotically, including after pause/resume or re-grabbing.
            let room = tiltVelocity >= 0 ? 1.2 - tilt : tilt + 1.2
            if room > 0 {
                let damping = max(Self.damping, abs(tiltVelocity) / room)
                let decay = exp(-damping * elapsed)
                pitch = (tilt + tiltVelocity * (-expm1(-damping * elapsed) / damping),
                         tiltVelocity * decay)
            } else {
                pitch = (tilt, 0)
            }
        }
        let clampedTilt = Self.clampTilt(pitch.position)
        return State(rotation: yaw.position, tilt: clampedTilt, yawVelocity: yaw.velocity,
                     tiltVelocity: clampedTilt == pitch.position ? pitch.velocity : 0)
    }

    private mutating func settle(at time: TimeInterval) {
        let state = state(at: time)
        rotation = state.rotation
        tilt = state.tilt
        yawVelocity = state.yawVelocity
        tiltVelocity = state.tiltVelocity
        epoch = time
    }

    private static func spring(position: Double, velocity: Double, target: Double,
                               elapsed: TimeInterval) -> (position: Double, velocity: Double) {
        let displacement = position - target
        let coefficient = velocity + springFrequency * displacement
        let decay = exp(-springFrequency * elapsed)
        return (target + (displacement + coefficient * elapsed) * decay,
                (velocity - springFrequency * coefficient * elapsed) * decay)
    }

    private static func clampTilt(_ value: Double) -> Double { min(1.2, max(-1.2, value)) }
}
