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

    var currentPercent: Double {
        guard batteryStatus.maxCapacityMah > 0 else { return 0 }
        return Double(batteryStatus.currentCapacityMah) * 100.0 / Double(batteryStatus.maxCapacityMah)
    }

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
        guard let session = batteryTrackerState?.session else { return nil }
        return max(0, session.startCapacityMah - batteryStatus.currentCapacityMah)
    }

    var usedPercent: Double? {
        guard let usedCapacityMah, batteryStatus.maxCapacityMah > 0 else { return nil }
        return Double(usedCapacityMah) * 100.0 / Double(batteryStatus.maxCapacityMah)
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
            runtimeState = BatteryRuntimeState(
                batteryTrackerState: batteryTrackerState,
                batteryStatus: try BatteryStatus.read()
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

    var statusText: String {
        guard let runtimeState else { return "Helper not running" }

        if
            status == .running,
            let session = runtimeState.batteryTrackerState?.session,
            let activeSeconds = runtimeState.activeSeconds,
            let usedPercent = runtimeState.usedPercent
        {
            let activeDuration = formatDuration(activeSeconds)
            let sleepSuffix: String
            if session.sleepSeconds > 0 {
                sleepSuffix = " + \(formatDuration(session.sleepSeconds)) sleep"
            } else {
                sleepSuffix = ""
            }
            return "Drained \(Int(usedPercent.rounded()))% over \(activeDuration)\(sleepSuffix)"
        }

        return chargeStatusText(runtimeState.chargeStatus)
    }

    func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func chargeStatusText(_ status: BatteryChargeStatus) -> String {
        switch status {
        case .charging:
            return "Charging"
        case .onHold:
            return "On Hold"
        case .charged:
            return "Charged"
        case .discharging:
            return ""
        }
    }

}
