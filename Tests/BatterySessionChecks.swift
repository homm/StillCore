import Foundation

@main
struct BatterySessionChecks {
    static func main() throws {
        checkDischargeScale()
        let now = Date()
        let engine = BatteryTrackerEngine()
        let legacy = BatteryTrackerSession(startedAt: now, startCapacityMah: 100,
                                           sleepSeconds: 0, lastCheckAt: now)
        var battery = BatteryStatus(reportedCurrentCapacity: 94, reportedMaxCapacity: 100,
                                    currentCapacityMah: 7600, maxCapacityMah: 8600,
                                    isOnACPower: false, isCharging: false, isFullyCharged: false,
                                    powerSaveMode: false)
        var old = BatteryTrackerState(schemaVersion: 2, session: legacy)
        var runtime = BatteryRuntimeState(batteryTrackerState: old, batteryStatus: battery)
        precondition(runtime.usedPercent == 6 && runtime.usedCapacityMah == nil)

        // The old helper can inherit the newer version number and drop unknown session keys.
        old.schemaVersion = 3
        runtime.batteryTrackerState = old
        precondition(runtime.usedPercent == 6 && runtime.usedCapacityMah == nil)
        let migrated = engine.update(state: old, batteryStatus: battery, now: now)
        precondition(migrated.session?.startChargeMah == 7600 && migrated.session?.startCapacityMah == 94)
        // Round-trip the session through the Codable shape of the shipped tracker.
        struct V2Session: Codable {
            var startedAt: Date
            var startCapacityMah: Int
            var sleepSeconds: Int
            var lastCheckAt: Date
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let oldReader = try decoder.decode(V2Session.self, from: encoder.encode(migrated.session))
        precondition(oldReader.startCapacityMah == 94, "The old app must read the same units as before")
        old.session = try decoder.decode(BatteryTrackerSession.self, from: encoder.encode(oldReader))
        battery.reportedCurrentCapacity = 90
        runtime = BatteryRuntimeState(batteryTrackerState: old, batteryStatus: battery)
        precondition(runtime.usedPercent == 4 && runtime.usedCapacityMah == nil)
        battery.currentCapacityMah -= 300
        let continued = engine.update(state: migrated, batteryStatus: battery, now: now.addingTimeInterval(5))
        runtime = BatteryRuntimeState(batteryTrackerState: continued, batteryStatus: battery)
        precondition(runtime.usedCapacityMah == 300, "Reading the next sample must retain the baseline")

        // On older systems the original helper recorded raw mAh instead.
        old.session?.startCapacityMah = 8000
        runtime.batteryTrackerState = old
        precondition(runtime.usedCapacityMah == 700 && runtime.usedPercent != nil,
                     "An OS upgrade must keep an unambiguous mAh baseline usable")
        old.session?.startCapacityMah = 99
        battery.currentCapacityMah = 75
        battery.reportedCurrentCapacity = 75
        battery.reportedMaxCapacity = 8600
        runtime = BatteryRuntimeState(batteryTrackerState: old, batteryStatus: battery)
        precondition(runtime.usedCapacityMah == 24, "Legacy capacities can be mAh even without raw keys")
        old.session?.startCapacityMah = 8000
        battery.currentCapacityMah = 7300
        runtime.batteryTrackerState = old
        battery.rawCurrentCapacity = 7300
        runtime.batteryStatus = battery
        precondition(runtime.usedCapacityMah == 700)
        let rawSession = engine.update(state: old, batteryStatus: battery, now: now).session
        precondition(rawSession?.startChargeMah == 7300 && rawSession?.startCapacityMah == 7300)
        battery.isOnACPower = true
        precondition(engine.update(state: continued, batteryStatus: battery, now: now).session == nil)
        print("PASS: battery sessions remain readable across tracker versions and capacity sources")
    }

    private static func checkDischargeScale() {
        let scale = BatteryDischargeScale(lowerMah: 0, upperMah: 0)
        let battery = BatteryStatus(reportedCurrentCapacity: 99, reportedMaxCapacity: 100,
                                    currentCapacityMah: 8532, maxCapacityMah: 8619,
                                    isOnACPower: true, isCharging: true, isFullyCharged: false, powerSaveMode: false)
        var runtime = BatteryRuntimeState(batteryStatus: battery, dischargeScale: scale)
        // Recorded while charging: the UI changed 99 -> 100 with no change in mAh.
        precondition(runtime.displayedPercent == 105)
        runtime.batteryStatus.reportedCurrentCapacity = 100
        precondition(runtime.displayedPercent == 105)
        runtime.batteryStatus.isOnACPower = false
        runtime.batteryStatus.isCharging = false
        precondition(runtime.displayedPercent == 105, "Unplugging must not change the scale")
        runtime.batteryStatus.currentCapacityMah = 8619
        precondition(abs(runtime.currentPercent - 105.3333) < 0.0001 && runtime.displayedPercent == 106)

        runtime.batteryStatus.currentCapacityMah = 9500
        runtime.batteryStatus.maxCapacityMah = 10000
        precondition(runtime.currentPercent == 100 && runtime.displayedPercent == 100)
        runtime.batteryStatus.currentCapacityMah += 1
        precondition(runtime.displayedPercent == 101, "The display must not saturate at 95% of usable capacity")
        let reserved = BatteryDischargeScale(lowerMah: 100, upperMah: 400)
        precondition(reserved.percent(chargeMah: 2100, fullMah: 10500) == 20)
        precondition(reserved.percent(chargeMah: 50, fullMah: 10500) == 0)
        runtime.batteryStatus.currentCapacityMah = 1000
        let now = Date()
        runtime.batteryTrackerState = BatteryTrackerState(session: .init(
            startedAt: now, startCapacityMah: 100, startChargeMah: 10000, sleepSeconds: 0, lastCheckAt: now
        ))
        precondition(abs(runtime.usedPercent! - 95.3333) < 0.0001, "Drain across the 20% knot uses both endpoints")
        runtime.dischargeScale = nil
        runtime.batteryStatus.reportedCurrentCapacity = 12
        precondition(runtime.displayedPercent == 12, "Unknown calibration must keep the reported percentage")
        print("PASS: one discharge scale on AC and battery, including the calibrated range above 100%")
    }
}
