import Foundation
import IOKit

enum BatteryStatusError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Battery information is unavailable."
        }
    }
}

struct BatteryStatus {
    var updateTime: Int?
    var rawCurrentCapacity: Int?
    var reportedCurrentCapacity: Int?
    var reportedMaxCapacity: Int?
    var remainingCapacity: Int?
    var fullChargeCapacity: Int?
    var currentCapacityMah: Int
    var maxCapacityMah: Int
    var isOnACPower: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    var powerSaveMode: Bool

    static var isAvailable: Bool {
        let entry = openBatteryEntry()
        guard entry != IO_OBJECT_NULL else {
            return false
        }
        defer { IOObjectRelease(entry) }
        return boolProperty(entry: entry, key: "BatteryInstalled") == true
    }

    static func read() throws -> BatteryStatus {
        let entry = openBatteryEntry()
        guard entry != IO_OBJECT_NULL else {
            throw BatteryStatusError.unavailable
        }
        defer { IOObjectRelease(entry) }

        let rawCurrent = intProperty(entry: entry, key: "AppleRawCurrentCapacity")
        let rawMax = intProperty(entry: entry, key: "AppleRawMaxCapacity")
        let reportedCurrent = intProperty(entry: entry, key: "CurrentCapacity")
        let reportedMax = intProperty(entry: entry, key: "MaxCapacity")
        let batteryData = IORegistryEntryCreateCFProperty(
            entry, "BatteryData" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let remaining = batteryData?["RemainingCapacity"] as? Int
        let full = batteryData?["FullChargeCapacity"] as? Int
        let currentCapacity: Int
        let maxCapacity: Int
        if let rawCurrent, let rawMax, rawMax > 0 {
            currentCapacity = rawCurrent
            maxCapacity = rawMax
        } else if let remaining, let full, full > 0 {
            currentCapacity = remaining
            maxCapacity = full
        } else if let reportedCurrent, let reportedMax, reportedMax > 100 {
            // Older drivers can publish mAh directly in the top-level pair.
            currentCapacity = reportedCurrent
            maxCapacity = reportedMax
        } else {
            throw BatteryStatusError.unavailable
        }
        guard
            boolProperty(entry: entry, key: "BatteryInstalled") == true,
            let isOnACPower = boolProperty(entry: entry, key: "ExternalConnected"),
            let isCharging = boolProperty(entry: entry, key: "IsCharging"),
            let isFullyCharged = boolProperty(entry: entry, key: "FullyCharged")
        else {
            throw BatteryStatusError.unavailable
        }

        return BatteryStatus(
            updateTime: intProperty(entry: entry, key: "UpdateTime"),
            rawCurrentCapacity: rawCurrent,
            reportedCurrentCapacity: reportedCurrent,
            reportedMaxCapacity: reportedMax,
            remainingCapacity: remaining,
            fullChargeCapacity: full,
            currentCapacityMah: currentCapacity,
            maxCapacityMah: maxCapacity,
            isOnACPower: isOnACPower,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            powerSaveMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func openBatteryEntry() -> io_registry_entry_t {
        var iterator = io_iterator_t()
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }
        return IOIteratorNext(iterator)
    }

    private static func intProperty(entry: io_registry_entry_t, key: String) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return value as? Int
        }
        return nil
    }

    private static func boolProperty(entry: io_registry_entry_t, key: String) -> Bool? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value as? Bool
        }
        return nil
    }
}
