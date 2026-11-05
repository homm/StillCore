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

    var name: String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 2 * Int(MAXCOMLEN) + 1) { buffer in
            let length = proc_name(id.pid, buffer.baseAddress, UInt32(buffer.count))
            return String(decoding: UnsafeRawBufferPointer(buffer).prefix(Int(max(length, 0))).prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func displayName(using path: inout [CChar]) -> String {
        let length = proc_pidpath(id.pid, &path, UInt32(path.count))
        if length > 0 {
            return path.withUnsafeBytes { buffer in
                let bytes = buffer.prefix(Int(length)).prefix { $0 != 0 }
                let start = bytes.lastIndex(of: 0x2F).map { $0 + 1 } ?? bytes.startIndex
                return String(decoding: bytes[start...], as: UTF8.self)
            }
        }
        let name = name
        return name.isEmpty ? String(id.pid) : name
    }

    func matches(name: String, pid: pid_t?, processIDs: Set<pid_t>? = nil) -> Bool {
        if let processIDs, !processIDs.contains(id.pid) { return false }
        if name.isEmpty { return true }
        if let pid {
            return pid == id.pid
        }
        return self.name.localizedCaseInsensitiveContains(name)
    }

    private func checkIdentity() throws {
        var usage = rusage_info_v6()
        if id.pid <= 0 || !ProcessSampler.readUsage(id.pid, into: &usage) || usage.ri_proc_start_abstime != id.start {
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

struct ProcessSnapshot: Sendable {
    var readings: [ProcessReading] = []
    var childrenByPID: [pid_t: [pid_t]] = [:]

    mutating func addProcess(pid: pid_t, parentPID: pid_t, responsiblePID: pid_t) {
        let parent = responsiblePID > 0 && responsiblePID != pid ? responsiblePID : parentPID
        childrenByPID[parent, default: []].append(pid)
    }

    func processIDs(root: pid_t, applicationPIDs: Set<pid_t>) -> Set<pid_t> {
        var result: Set<pid_t> = [root]
        var pending = [root]
        while let parent = pending.popLast() {
            for child in childrenByPID[parent, default: []] {
                if !applicationPIDs.contains(child), result.insert(child).inserted {
                    pending.append(child)
                }
            }
        }
        return result
    }
}

final class ProcessSampler {
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
        }
        return nil
    }()

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

    private typealias Counters = (cpu: UInt64, energy: UInt64, gpu: UInt64?, qos: QoSActivity)
    private var previous: [ProcessReading.ID: Counters] = [:]
    private var current: [ProcessReading.ID: Counters] = [:]
    private var lastTime = mach_absolute_time()
    private let nsPerTick: Double

    init() {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        nsPerTick = Double(scale.numer) / Double(scale.denom)
    }

    static func readUsage(_ pid: pid_t, into info: inout rusage_info_v6) -> Bool {
        withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) == 0
        }
    }

    func sample() -> ProcessSnapshot {
        let now = mach_absolute_time()
        let ticks = Double(now - lastTime)
        lastTime = now
        let uid = geteuid()
        var snapshot = ProcessSnapshot()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var bytes = 0
        if sysctl(&mib, UInt32(mib.count), nil, &bytes, nil, 0) != 0 { return snapshot }
        let processSize = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: bytes / processSize + 64)
        bytes = processes.count * processSize
        if sysctl(&mib, UInt32(mib.count), &processes, &bytes, nil, 0) != 0 { return snapshot }
        let gpuTimes = Self.gpuTimes()
        snapshot.readings.reserveCapacity(bytes / processSize)
        var usage = rusage_info_v6()
        for process in processes.prefix(bytes / processSize) {
            let pid = process.kp_proc.p_pid
            if pid <= 0 { continue }
            snapshot.addProcess(pid: pid, parentPID: process.kp_eproc.e_ppid,
                                responsiblePID: Self.responsiblePID?(pid) ?? -1)
            if uid != 0 && process.kp_eproc.e_ucred.cr_uid != uid { continue }
            if Self.readUsage(pid, into: &usage) {
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
                snapshot.readings.append(ProcessReading(
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
        swap(&previous, &current)
        current.removeAll(keepingCapacity: true)
        return snapshot
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
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(client, &properties, nil, 0) != KERN_SUCCESS { continue }
                let clientProperties = properties!.takeRetainedValue() as NSDictionary
                if let creator = clientProperties["IOUserClientCreator"] as? String, creator.hasPrefix("pid "),
                   let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                   let usage = clientProperties["AppUsage"] as? NSArray {
                    for case let entry as NSDictionary in usage {
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
