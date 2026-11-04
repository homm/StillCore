import Foundation
import IOKit

struct ProcessReading: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let pid: pid_t
        let start: UInt64
    }

    let id: ID
    let isBackground: Bool
    let cpu: Double?
    let gpu: Double?
    let memory: UInt64
    let power: Double?

    func displayName(using path: inout [CChar]) -> String {
        let length = proc_pidpath(id.pid, &path, UInt32(path.count))
        if length > 0 {
            return path.withUnsafeBytes { buffer in
                let bytes = buffer.prefix(Int(length)).prefix { $0 != 0 }
                let start = bytes.lastIndex(of: 0x2F).map { $0 + 1 } ?? bytes.startIndex
                return String(decoding: bytes[start...], as: UTF8.self)
            }
        }
        let nameLength = proc_name(id.pid, &path, UInt32(path.count))
        return nameLength > 0 ? path.withUnsafeBytes {
            String(decoding: $0.prefix(Int(nameLength)).prefix { $0 != 0 }, as: UTF8.self)
        } : String(id.pid)
    }

    private func checkIdentity() throws {
        if id.pid <= 0 || ProcessSampler.usage(id.pid)?.ri_proc_start_abstime != id.start {
            throw POSIXError(.ESRCH)
        }
    }

    var externalBackgroundPolicy: Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        if proc_pidinfo(id.pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_flags & UInt32(PROC_FLAG_EXT_DARWINBG) != 0
        }
        return nil
    }

    func setBackgroundPolicy(_ enabled: Bool) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        command.arguments = [enabled ? "-b" : "-B", "-p", String(id.pid)]
        let errors = Pipe()
        command.standardError = errors
        try checkIdentity()
        try command.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        if command.terminationStatus != 0 {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "taskpolicy", code: Int(command.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func send(signal: Int32) throws {
        try checkIdentity()
        if kill(id.pid, signal) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

final class ProcessSampler {
    struct QoSActivity {
        let backgroundTime: UInt64
        let otherTime: UInt64
        let isBackground: Bool

        init(usage: rusage_info_v6, previous: QoSActivity?) {
            backgroundTime = usage.ri_cpu_time_qos_background + usage.ri_cpu_time_qos_maintenance
            otherTime = usage.ri_cpu_time_qos_default + usage.ri_cpu_time_qos_utility
                + usage.ri_cpu_time_qos_legacy + usage.ri_cpu_time_qos_user_initiated
                + usage.ri_cpu_time_qos_user_interactive
            if let previous, backgroundTime >= previous.backgroundTime, otherTime >= previous.otherTime {
                if otherTime > previous.otherTime {
                    isBackground = false
                } else if backgroundTime > previous.backgroundTime {
                    isBackground = true
                } else {
                    isBackground = previous.isBackground
                }
            } else {
                isBackground = false
            }
        }
    }

    private var previous: [ProcessReading.ID: (cpu: UInt64, energy: UInt64, gpu: UInt64?, qos: QoSActivity)] = [:]
    private var lastTime = mach_absolute_time()
    private let nsPerTick: Double

    init() {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        nsPerTick = Double(scale.numer) / Double(scale.denom)
    }

    static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return result == 0 ? info : nil
    }

    func sample() -> [ProcessReading] {
        let now = mach_absolute_time()
        let ticks = Double(now - lastTime)
        lastTime = now
        let capacity = Int(max(0, proc_listallpids(nil, 0))) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        let gpuTimes = Self.gpuTimes()
        var current: [ProcessReading.ID: (cpu: UInt64, energy: UInt64, gpu: UInt64?, qos: QoSActivity)] = [:]
        var rows: [ProcessReading] = []
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            if let usage = Self.usage(pid) {
                let id = ProcessReading.ID(pid: pid, start: usage.ri_proc_start_abstime)
                let cpu = usage.ri_user_time + usage.ri_system_time
                let gpu = gpuTimes[pid]
                let energy = usage.ri_energy_nj
                let old = previous[id]
                let qos = QoSActivity(usage: usage, previous: old?.qos)
                func rate(_ value: UInt64, _ baseline: UInt64?, _ factor: Double) -> Double? {
                    if let baseline, value >= baseline, ticks > 0 {
                        return Double(value - baseline) / ticks * factor
                    }
                    return nil
                }
                rows.append(ProcessReading(
                    id: id,
                    isBackground: qos.isBackground,
                    cpu: rate(cpu, old?.cpu, 100),
                    gpu: gpu.flatMap { rate($0, old?.gpu, 100 / nsPerTick) }.map { min($0, 100) },
                    memory: usage.ri_resident_size,
                    power: rate(energy, old?.energy, 1 / nsPerTick)
                ))
                current[id] = (cpu, energy, gpu, qos)
            }
        }
        previous = current
        return rows
    }

    private static func gpuTimes() -> [pid_t: UInt64] {
        var times: [pid_t: UInt64] = [:]
        var services: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) != KERN_SUCCESS {
            return times
        }
        defer { IOObjectRelease(services) }
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &clients) != KERN_SUCCESS { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, nil, 0)?.takeRetainedValue() as? String
                if let creator, creator.hasPrefix("pid "),
                   let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                   let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]] {
                    for entry in usage {
                        if let time = entry["accumulatedGPUTime"] as? UInt64 {
                            times[pid, default: 0] += time
                        }
                    }
                }
            }
        }
        return times
    }
}
