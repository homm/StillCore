import Foundation
import MacmonSwift

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

final class MetricsWorker: @unchecked Sendable {
    private let schedule: MetricsSchedule
    private let processLock = NSLock()
    // Both fields are protected by processLock.
    private var processSampler: ProcessSampler?
    private var processShowing: UUID?

    init(interval: Duration,
         onSample: @escaping @MainActor @Sendable (Metrics, ProcessSnapshot?) -> Void,
         onError: @escaping @MainActor @Sendable (String) -> Void) {
        schedule = MetricsSchedule(interval: interval)

        Thread.detachNewThread {
            do {
                let sampler = try Sampler()
                defer { sampler.close() }
                while true {
                    self.schedule.waitForNextSample()
                    let metrics = try sampler.metrics()
                    let (showing, processes) = self.sampleProcesses()
                    DispatchQueue.main.async {
                        let isCurrent = self.processShowing == showing
                        onSample(metrics, isCurrent ? processes : nil)
                    }
                }
            } catch {
                let message = String(describing: error)
                DispatchQueue.main.async {
                    onError(message)
                }
            }
        }
    }

    @MainActor
    func setProcessSampler(_ sampler: sending ProcessSampler?) {
        processLock.lock()
        defer { processLock.unlock() }
        processShowing = sampler == nil ? nil : UUID()
        processSampler = sampler
    }

    private func sampleProcesses() -> (showing: UUID?, snapshot: ProcessSnapshot?) {
        processLock.lock()
        let sampler = processSampler
        let showing = processShowing
        processLock.unlock()
        return (showing, sampler?.sample())
    }

    func setInterval(_ interval: Duration) {
        schedule.setInterval(interval)
    }
}
