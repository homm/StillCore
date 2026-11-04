import AppKit
import Combine
import Foundation
import ServiceManagement

enum BatteryChargeStatus {
    case charging
    case onHold
    case charged
    case discharging
}

struct BatteryRuntimeState {
    var batteryTrackerState: BatteryTrackerState?
    var batteryStatus: BatteryStatus
    var dischargeScale: BatteryDischargeScale?

    var currentPercent: Double {
        if let percent = dischargeScale?.percent(chargeMah: batteryStatus.currentCapacityMah, fullMah: batteryStatus.maxCapacityMah) {
            return percent
        }
        if let current = batteryStatus.reportedCurrentCapacity, let max = batteryStatus.reportedMaxCapacity, max > 0 {
            return min(100, (Double(current) * 100 / Double(max)).rounded())
        }
        return Double(batteryStatus.currentCapacityMah) * 100 / Double(batteryStatus.maxCapacityMah)
    }

    var displayedPercent: Int { max(1, Int(currentPercent.rounded(.up))) }

    var chargeStatus: BatteryChargeStatus {
        guard batteryStatus.isOnACPower else { return .discharging }
        if batteryStatus.isCharging { return .charging }
        if batteryStatus.isFullyCharged { return .charged }
        return .onHold
    }

    var activeSeconds: Int? {
        guard let session = batteryTrackerState?.session else { return nil }
        return max(0, Int(Date().timeIntervalSince(session.startedAt).rounded()) - session.sleepSeconds)
    }

    var usedCapacityMah: Int? {
        if let session = batteryTrackerState?.session {
            if let start = session.startChargeMah {
                return max(0, start - batteryStatus.currentCapacityMah)
            }
            // An untagged baseline above 100 cannot be a legacy percentage,
            // even when an OS upgrade has since removed the raw keys.
            if session.startCapacityMah > 100 || batteryStatus.rawCurrentCapacity != nil
                || (batteryStatus.reportedMaxCapacity ?? 0) > 100 {
                return max(0, session.startCapacityMah - batteryStatus.currentCapacityMah)
            }
        }
        return nil
    }

    var usedPercent: Double? {
        if let usedCapacityMah, batteryStatus.maxCapacityMah > 0 {
            // Use the same full capacity at both ends: a revised capacity
            // estimate by itself does not mean any charge was consumed.
            if let scale = dischargeScale,
               let start = scale.percent(chargeMah: batteryStatus.currentCapacityMah + usedCapacityMah, fullMah: batteryStatus.maxCapacityMah) {
                return max(0, start - currentPercent)
            }
            return Double(usedCapacityMah) * 100.0 / Double(batteryStatus.maxCapacityMah)
        }
        if let session = batteryTrackerState?.session, session.startChargeMah == nil,
           batteryStatus.reportedMaxCapacity == 100, let current = batteryStatus.reportedCurrentCapacity {
            return Double(max(0, session.startCapacityMah - current))
        }
        return nil
    }
}

@MainActor
final class BatteryTrackerService: HelperService {
    static let isBatteryAvailable = BatteryStatus.isAvailable
    static let shared = BatteryTrackerService()
    @Published private(set) var runtimeState: BatteryRuntimeState?
    private var runtimeError: String?

    // Lets non-SwiftUI code observe runtimeState without exposing write access.
    var runtimeStatePublisher: AnyPublisher<BatteryRuntimeState?, Never> {
        $runtimeState.eraseToAnyPublisher()
    }

    private let store = BatterySessionStore()

    private init() {
        super.init(service: .agent(plistName: BatteryTrackerConstants.launchAgentPlistName),
                   helperName: "BatteryTrackerHelper")
    }

    override func initialize() {
        if !Self.isBatteryAvailable { return }
        super.initialize()
    }

    override func ensureRunning() async throws {
        // A record left by the old process cannot confirm this launch.
        let previousHeartbeat = try? store.load()?.heartbeatAt
        let deadline = ContinuousClock.now + .seconds(15)
        while status == .starting && isRegistered {
            let state: BatteryTrackerState?
            do {
                state = try store.load()
            } catch {
                throw HelperFailure("State read failed: \(error.localizedDescription)")
            }
            if let error = state?.lastError { throw HelperFailure(error) }
            if state?.isRunning(after: previousHeartbeat) == true {
                refresh()
                return
            }
            if ContinuousClock.now >= deadline {
                throw HelperFailure("The battery tracker did not update its heartbeat. Try starting it again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    override func refresh() {
        super.refresh()
        var batteryTrackerState: BatteryTrackerState?
        var stateReadError: String?
        var batteryStatusReadError: String?

        do {
            batteryTrackerState = try store.load()
        } catch {
            stateReadError = "State read failed: \(error.localizedDescription)"
        }

        do {
            let battery = try BatteryStatus.read()
            var scale = runtimeState?.dischargeScale
            if runtimeState == nil || battery.updateTime == nil || battery.updateTime != runtimeState?.batteryStatus.updateTime {
                scale = BatteryDischargeScale.read()
            }
            runtimeState = BatteryRuntimeState(
                batteryTrackerState: batteryTrackerState,
                batteryStatus: battery,
                dischargeScale: scale
            )
        } catch {
            runtimeState = nil
            batteryStatusReadError = "Battery read failed: \(error.localizedDescription)"
        }

        let previousRuntimeError = runtimeError
        runtimeError = stateReadError ?? batteryStatusReadError ?? batteryTrackerState?.lastError
        if previousRuntimeError != nil && errorMessage == previousRuntimeError && runtimeError == nil {
            errorMessage = nil
        }

        if isRegistered && status != .starting {
            if let helperError = stateReadError ?? batteryTrackerState?.lastError {
                if status != .stopped || errorMessage != helperError { reportFailure(helperError) }
            } else if batteryTrackerState?.isRunning() == true {
                // A recovered agent needs no new start request.
                if status == .stopped {
                    errorMessage = nil
                    status = .running
                }
            } else if status == .running {
                reportFailure("The battery tracker stopped updating its heartbeat. Try starting it again.")
            }
        }
        if let runtimeError, errorMessage != runtimeError { errorMessage = runtimeError }
    }

    func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
