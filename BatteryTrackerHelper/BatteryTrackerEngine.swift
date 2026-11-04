import Foundation

struct BatteryTrackerEngine {
    private static let pollInterval: TimeInterval = 5
    private static let sleepThreshold: TimeInterval = 10

    private let store: BatterySessionStore
    private let helperVersion: String

    init(
        store: BatterySessionStore = BatterySessionStore(),
        helperVersion: String = BatteryTrackerEngine.defaultHelperVersion()
    ) {
        self.store = store
        self.helperVersion = helperVersion
    }

    func run() -> Never {
        while true {
            autoreleasepool {
                let cycleStartedAt = Date()

                do {
                    var state = try store.load() ?? makeState(now: cycleStartedAt)
                    let batteryStatus = try BatteryStatus.read()
                    state = update(state: state, batteryStatus: batteryStatus, now: cycleStartedAt)
                    try store.save(state)
                } catch {
                    do {
                        try store.save(makeErrorState(message: error.localizedDescription, now: cycleStartedAt))
                    } catch {
                        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    }
                }

                let elapsed = Date().timeIntervalSince(cycleStartedAt)
                let sleepDuration = max(1, Int((Self.pollInterval - elapsed).rounded(.up)))
                sleep(UInt32(sleepDuration))
            }
        }
    }

    func update(state: BatteryTrackerState, batteryStatus: BatteryStatus, now: Date) -> BatteryTrackerState {
        var nextState = state
        nextState.schemaVersion = BatteryTrackerState.currentSchemaVersion
        var session = nextState.session

        if let previousCheck = session?.lastCheckAt {
            let elapsed = now.timeIntervalSince(previousCheck)
            if elapsed > Self.sleepThreshold {
                session?.sleepSeconds += max(0, Int(elapsed.rounded()) - Int(Self.pollInterval))
            }
        }

        if batteryStatus.isOnACPower {
            session = nil
        } else {
            // An older writer drops startChargeMah but can preserve schemaVersion.
            if session?.startChargeMah == nil {
                session = BatteryTrackerSession(
                    startedAt: now,
                    startCapacityMah: batteryStatus.rawCurrentCapacity
                        ?? batteryStatus.reportedCurrentCapacity ?? batteryStatus.currentCapacityMah,
                    startChargeMah: batteryStatus.currentCapacityMah,
                    sleepSeconds: 0,
                    lastCheckAt: now
                )
            }

            if var activeSession = session {
                activeSession.lastCheckAt = now
                session = activeSession
            }
        }

        nextState.helperVersion = helperVersion
        nextState.pid = getpid()
        nextState.heartbeatAt = now
        nextState.session = session
        nextState.lastError = nil
        return nextState
    }

    private func makeState(now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            session: nil,
            lastError: nil
        )
    }

    private func makeErrorState(message: String, now: Date) -> BatteryTrackerState {
        BatteryTrackerState(
            helperVersion: helperVersion,
            pid: getpid(),
            heartbeatAt: now,
            session: nil,
            lastError: message
        )
    }

    private static func defaultHelperVersion() -> String {
        let infoDictionary = Bundle.main.infoDictionary
        return (infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (infoDictionary?["CFBundleVersion"] as? String)
            ?? "1"
    }
}
