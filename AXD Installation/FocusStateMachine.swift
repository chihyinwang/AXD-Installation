import Foundation

struct FocusTickResult {
    let didStart: Bool
    let didEnd: Bool
}

final class FocusStateMachine {
    private let timing: FocusTimingConfig
    private var remaining: Float = 0
    private var delayRemaining: Float = 0

    var isActive: Bool { remaining > 0 }
    var simulationTimeScale: Float { isActive ? timing.timeScale : 1.0 }

    init(timing: FocusTimingConfig) {
        self.timing = timing
    }

    func scheduleAfterDelay() {
        delayRemaining = timing.delay
        remaining = 0
    }

    func activateNow() {
        delayRemaining = 0
        remaining = timing.duration
    }

    func reset() {
        remaining = 0
        delayRemaining = 0
    }

    func tick(realDeltaTime dt: Float) -> FocusTickResult {
        guard dt > 0 else {
            return FocusTickResult(didStart: false, didEnd: false)
        }

        var didStart = false
        var didEnd = false

        if delayRemaining > 0 {
            delayRemaining -= dt
            if delayRemaining <= 0 {
                delayRemaining = 0
                remaining = timing.duration
                didStart = true
            }
        }

        if remaining > 0 {
            remaining -= dt
            if remaining <= 0 {
                remaining = 0
                didEnd = true
            }
        }

        return FocusTickResult(didStart: didStart, didEnd: didEnd)
    }
}
