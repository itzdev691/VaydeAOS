import Foundation
import Testing
@testable import VaydeAOSCore

@Suite("Connection globe momentum")
struct ConnectionMotionTests {
    private func flick(direction: Double = 1) -> ConnectionMotion {
        var motion = ConnectionMotion(at: 0)
        motion.setAdvancing(true, at: 0)
        for step in 0...18 {
            motion.drag(rotation: direction * 0.05, tilt: 0, at: Double(step) / 60)
        }
        motion.endDrag(at: 0.3)
        return motion
    }

    @Test func dragHasWeightAndSettlesWithoutOscillation() {
        var motion = ConnectionMotion(at: 0)
        motion.setAdvancing(true, at: 0)
        motion.drag(rotation: 1, tilt: 0.3, at: 0)
        let start = motion.position(at: 0).rotation
        let early = motion.position(at: 0.03).rotation
        let middle = motion.position(at: 0.15).rotation
        let settled = motion.position(at: 1).rotation
        #expect(abs(start - 0.4) < 0.000_001)
        #expect(early > start && early < start + 0.15)
        #expect(middle > early && middle < 1.4)
        #expect(abs(settled - 1.4) < 0.0001)
    }

    @Test(arguments: [-1.0, 1.0])
    func flickCoastsForSecondsThenReturnsToAmbientRotation(direction: Double) {
        let motion = flick(direction: direction)
        let start = motion.position(at: 0.3).rotation
        let early = motion.position(at: 0.55).rotation
        #expect((early - start) * direction > 0)
        let lateTravel = motion.position(at: 2.55).rotation - motion.position(at: 2.3).rotation
        #expect((lateTravel - 0.055 * 0.25) * direction > 0.05)
        let settledTravel = motion.position(at: 30.55).rotation - motion.position(at: 30.3).rotation
        #expect(abs(settledTravel - 0.055 * 0.25) < 0.000_001)
    }

    @Test func releasePreservesPositionAndVelocity() {
        var motion = ConnectionMotion(at: 0)
        motion.setAdvancing(true, at: 0)
        motion.drag(rotation: 1, tilt: 0.3, at: 0)
        let before = motion.position(at: 0.1)
        let previous = motion.position(at: 0.09999)
        motion.endDrag(at: 0.1)
        let after = motion.position(at: 0.1)
        let next = motion.position(at: 0.10001)
        #expect(abs(after.rotation - before.rotation) < 0.000_001)
        #expect(abs(after.tilt - before.tilt) < 0.000_001)
        #expect(abs((next.rotation - after.rotation) - (before.rotation - previous.rotation)) < 0.000_000_1)
        #expect(abs((next.tilt - after.tilt) - (before.tilt - previous.tilt)) < 0.000_000_1)
    }

    @Test func holdingBeforeReleaseLetsMomentumSettle() {
        var motion = ConnectionMotion(at: 0)
        motion.setAdvancing(true, at: 0)
        motion.drag(rotation: 1, tilt: 0, at: 0)
        motion.endDrag(at: 2)
        let start = motion.position(at: 2).rotation
        #expect(motion.position(at: 2.25).rotation - start < 0.01)
    }

    @Test func pauseAndResumePreservePositionAndRemainingMomentum() {
        var motion = flick()
        let before = motion.position(at: 0.5)
        motion.setAdvancing(false, at: 0.5)
        #expect(abs(motion.position(at: 100).rotation - before.rotation) < 0.000_001)
        #expect(abs(motion.position(at: 100).tilt - before.tilt) < 0.000_001)
        motion.setAdvancing(true, at: 100)
        #expect(abs(motion.position(at: 100).rotation - before.rotation) < 0.000_001)
        #expect(motion.position(at: 100.1).rotation > before.rotation)
    }

    @Test func grabbingMovingGlobePreservesPositionAndBrakesGradually() {
        var motion = flick()
        let before = motion.position(at: 0.5).rotation
        motion.drag(rotation: 0, tilt: 0, at: 0.5)
        #expect(abs(motion.position(at: 0.5).rotation - before) < 0.000_001)
        #expect(motion.position(at: 0.51).rotation > before)
        #expect(abs(motion.position(at: 2).rotation - before) < 0.0001)
    }

    @Test func springIsIndependentOfSamplingRate() {
        var sparse = ConnectionMotion(at: 0)
        sparse.setAdvancing(true, at: 0)
        sparse.drag(rotation: 1, tilt: 0.3, at: 0)
        var dense = sparse
        for step in 1...60 {
            dense.drag(rotation: 0, tilt: 0, at: Double(step) / 60)
        }
        #expect(abs(sparse.position(at: 1).rotation - dense.position(at: 1).rotation) < 0.000_001)
        #expect(abs(sparse.position(at: 1).tilt - dense.position(at: 1).tilt) < 0.000_001)
    }

    @Test func pausedDraggingFollowsPointerAndTiltStaysBounded() {
        var motion = ConnectionMotion(at: 0)
        motion.drag(rotation: 1, tilt: 10, at: 0)
        #expect(motion.position(at: 1).rotation == 1.4)
        #expect(motion.position(at: 1).tilt == 1.2)
        motion.drag(rotation: .infinity, tilt: .nan, at: 1)
        motion.endDrag(at: 1)
        #expect(motion.position(at: 2).rotation.isFinite)
        #expect(motion.position(at: 2).tilt.isFinite)
        motion.setAdvancing(true, at: 2)
        motion.drag(rotation: 0, tilt: -20, at: 2)
        motion.endDrag(at: 2.2)
        #expect(abs(motion.position(at: 5).tilt + 1.2) < 0.000_001)
    }

    @Test(arguments: [-1.0, 1.0])
    func verticalReleaseSlowsBeforeTheTiltLimit(direction: Double) {
        var motion = ConnectionMotion(at: 0)
        motion.setAdvancing(true, at: 0)
        motion.drag(rotation: 0, tilt: direction * 10, at: 0)
        let before = motion.position(at: 0.09999).tilt
        let release = motion.position(at: 0.1).tilt
        motion.endDrag(at: 0.1)
        let next = motion.position(at: 0.10001).tilt
        #expect(abs((next - release) - (release - before)) < 0.000_000_1)
        var previous = release
        var previousTravel = Double.infinity
        for frame in 1...60 {
            let current = motion.position(at: 0.1 + Double(frame) / 60).tilt
            let travel = (current - previous) * direction
            #expect(abs(current) < 1.2)
            #expect(travel > 0)
            #expect(travel < previousTravel)
            previous = current
            previousTravel = travel
        }
    }
}
