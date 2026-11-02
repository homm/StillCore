import Foundation

// The condition protects the schedule shared by the metrics thread and interval controls.
final class MetricsSchedule: @unchecked Sendable {
    private let condition = NSCondition()
    private var deadline: ContinuousClock.Instant
    private var interval: Duration

    var nextSample: ContinuousClock.Instant {
        condition.lock()
        defer { condition.unlock() }
        return deadline
    }

    init(interval: Duration, now: ContinuousClock.Instant = .now) {
        self.interval = interval
        deadline = now + interval
    }

    func setInterval(_ interval: Duration, now: ContinuousClock.Instant = .now) {
        condition.lock()
        defer { condition.unlock() }
        self.interval = interval
        let next = min(deadline, now + interval)
        if next < deadline {
            deadline = next
            condition.signal()
        }
    }

    func waitForNextSample() {
        condition.lock()
        defer { condition.unlock() }
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
        }
        let startedAt = ContinuousClock.now
        // Advance from the latest due tick, keeping the original schedule after delays.
        while deadline + interval <= startedAt {
            deadline += interval
        }
        deadline += interval
    }
}
