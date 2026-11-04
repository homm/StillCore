import IOKit

struct BatteryDischargeScale {
    let lowerMah: Int
    let upperMah: Int

    // Continue the discharge segment through (20, 20) and (95, 100)
    // even above the system's 100% plateau, whether on AC or battery.
    func percent(chargeMah: Int, fullMah: Int) -> Double? {
        let usable = fullMah - lowerMah - upperMah
        if usable <= 0 { return nil }
        let raw = 100 * Double(max(0, chargeMah - lowerMah)) / Double(usable)
        if raw <= 20 { return raw }
        return 20 + (raw - 20) * 80 / (95 - 20)
    }

    static func read() -> Self? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSMCKeysEndpoint"))
        if service == IO_OBJECT_NULL { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { return nil }
        defer { IOServiceClose(connection) }

        // AppleSMC's selector 2 exchanges 80-byte SMCKeyData packets on Apple silicon.
        func call(_ request: [UInt8]) -> [UInt8]? {
            var reply = [UInt8](repeating: 0, count: 80)
            var size = reply.count
            let status = IOConnectCallStructMethod(connection, 2, request, request.count, &reply, &size)
            if status == KERN_SUCCESS && size == reply.count && reply[40] == 0 { return reply }
            return nil
        }

        func readReserve(_ key: String) -> Int? {
            var request = [UInt8](repeating: 0, count: 80)
            // The FourCC is a native-endian UInt32 in the packet.
            request[0..<4] = ArraySlice(key.utf8.reversed())
            request[42] = 9 // Read key info.
            if let info = call(request),
               info[28..<32].elementsEqual([4, 0, 0, 0]),
               info[32..<36].elementsEqual("ui32".utf8.reversed()) {
                request[28..<40] = info[28..<40]
                request[42] = 5 // Read value.
                if let value = call(request) {
                    return value.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 48, as: UInt32.self)) }
                }
            }
            return nil
        }

        if let lower = readReserve("BRC0"), let upper = readReserve("BRC1") {
            return Self(lowerMah: lower, upperMah: upper)
        }
        return nil
    }
}
