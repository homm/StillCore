// Run with: powermetrics --samplers cpu_power --format plist -i 500 | pgauge

import Foundation

struct FileHandleLineSequence: Sequence, IteratorProtocol {
    let handle: FileHandle
    private let NL: UInt8 = 0x0A
    private let compactThreshold = 64 * 1024

    private var buffer = Data()
    private var readIdx: Data.Index = 0
    private var eof = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func next() -> Data? {
        while true {
            if let nl = buffer[readIdx...].firstIndex(of: NL) {
                let line = Data(buffer[readIdx...nl])
                readIdx = buffer.index(after: nl)

                if readIdx >= compactThreshold {
                    buffer.removeSubrange(0..<readIdx)
                    readIdx = 0
                }
                return line
            }

            if eof {
                if readIdx < buffer.endIndex {
                    let tail = buffer[readIdx..<buffer.endIndex]
                    readIdx = buffer.endIndex
                    return Data(tail)
                }
                return nil
            }

            autoreleasepool {
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    eof = true
                }
            }
        }
    }
}

// MARK: - 2) PrunedLineSequence — тримит строки и вырезает большие массивы после нужных ключей

let K_DVFM  = Data("<key>dvfm_states</key>".utf8)
let K_DUTY  = Data("<key>duty_cycles</key>".utf8)
let K_CST   = Data("<key>c_states</key>".utf8)
let ARR_END = Data("</array>".utf8)
let PLIST_END = Data("</plist>".utf8)

@inline(__always)
func trimAscii(_ d: Data) -> Data.SubSequence {
    var i = d.startIndex
    var j = d.endIndex
    while i < j {
        let b = d[i]
        if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A || b == 0x00 {
            i = d.index(after: i)
        } else { break }
    }
    while i < j {
        let b = d[d.index(before: j)]
        if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A || b == 0x00 {
            j = d.index(before: j)
        } else { break }
    }
    return d[i..<j]
}

struct PrunedLineSequence<Base: Sequence>: Sequence, IteratorProtocol where Base.Element == Data {
    private var iter: Base.Iterator
    private var skippingArray = false

    init(base: Base) {
        self.iter = base.makeIterator()
    }

    mutating func next() -> Data? {
        while let raw = iter.next() {
            let trimmed = trimAscii(raw)
            if trimmed.isEmpty {
                continue
            }

            if skippingArray {
                if trimmed.elementsEqual(ARR_END) {
                    skippingArray = false
                }
                continue
            }

            if trimmed.elementsEqual(K_DVFM)
                || trimmed.elementsEqual(K_DUTY)
                || trimmed.elementsEqual(K_CST) {
                skippingArray = true
                continue
            }

            return Data(trimmed) // отдаем уже отtrimленную строку
        }
        return nil
    }
}

// MARK: - 3) PlistSequence — собирает строки в один plist (до </plist>) и отдаёт Data

struct PlistSequence<Base: Sequence>: Sequence, IteratorProtocol where Base.Element == Data {
    private var iter: Base.Iterator
    private var current = Data()

    init(base: Base) {
        self.iter = base.makeIterator()
    }

    mutating func next() -> [String: Any]? {
        while let line = iter.next() {
            current.append(line)

            if line.elementsEqual(PLIST_END) {
                var fmt = PropertyListSerialization.PropertyListFormat.xml
                do {
                    let plist = try PropertyListSerialization.propertyList(from: current, options: [], format: &fmt)
                    current.removeAll(keepingCapacity: true)
                    guard let dict = plist as? [String: Any] else { continue }
                    return dict
                } catch {
                    current.removeAll(keepingCapacity: true)
                    continue
                }
            }
        }
        return nil
    }
}


struct Stats: Codable {
    struct Power: Codable {
        var cpu: Double?
        var gpu: Double?
        var total: Double?
    }
    struct CPUCluster: Codable {
        var name: String
        var freq: Double
        var load: Double
        var number: Int
    }
    var power: Power
    var cpu: [CPUCluster]
}

final class StatsPrinter {
    private let perCoreLoad: Bool
    private var headersPrinted = false

    init(perCoreLoad: Bool = false) {
        self.perCoreLoad = perCoreLoad
    }

    // feed: возвращает Stats и (опционально) печатает
    func feed(_ stats: [String: Any], printJSON: Bool = true) -> Stats? {
        let unified: Stats?
        if stats["clusters"] != nil {
            unified = convertARM(stats)
        } else {
            unified = convertIntel(stats)
        }
        guard let u = unified else { return nil }

        if !headersPrinted {
            printHeaders(stats: u)
        }
        printStats(u)
        return u
    }

    // Утилиты для безопасного извлечения чисел
    @inline(__always) private func maybeDouble(_ v: Any?) -> Double? {
        switch v {
        case let d as Double:   return d
        case let i as Int:      return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private func convertARM(_ s: [String: Any]) -> Stats? {
        let power = Stats.Power(
            cpu:   maybeDouble(s["cpu_power"]).map { $0 / 1000.0 },
            gpu:   maybeDouble(s["gpu_power"]).map { $0 / 1000.0 },
            total: maybeDouble(s["combined_power"]).map { $0 / 1000.0 }
        )

        guard let clusters = s["clusters"] as? [[String: Any]] else { return nil }

        let cpus: [Stats.CPUCluster] = clusters.compactMap { cl in
            guard let cpus = cl["cpus"] as? [[String: Any]] else { return nil}
            let sumUtil = cpus.reduce(0.0) { acc, cpu in
                let idle = maybeDouble(cpu["idle_ratio"]) ?? 0
                let down = maybeDouble(cpu["down_ratio"]) ?? 0
                return acc + max(0, 1 - idle - down)
            }

            return Stats.CPUCluster(
                name: (cl["name"] as? String) ?? "?",
                freq: (maybeDouble(cl["freq_hz"]) ?? 0) / 1e9,
                load: sumUtil / Double(perCoreLoad ? 1 : max(cpus.count, 1)),
                number: cpus.count
            )
        }

        return Stats(power: power, cpu: cpus)
    }

    private func convertIntel(_ s: [String: Any]) -> Stats? {
        let power = Stats.Power(
            cpu:   nil,
            gpu:   nil,
            total: maybeDouble(s["package_watts"])
        )
        guard let packages = s["packages"] as? [[String: Any]] else { return nil }

        func pkgFreqGHz(_ cores: [[String: Any]]) -> Double {
            var sum = 0.0, n = 0
            for core in cores {
                if let cpus = core["cpus"] as? [[String: Any]] {
                    for cpu in cpus {
                        if let f = maybeDouble(cpu["freq_hz"]) {
                            sum += f
                            n += 1
                        }
                    }
                }
            }
            let avg = n > 0 ? sum / Double(n) : 0
            return avg / 1e9
        }

        let cpus: [Stats.CPUCluster] = packages.enumerated().compactMap { (i, pkg) in
            guard let cores = pkg["cores"] as? [[String: Any]] else { return nil }
            let avgNumCores = maybeDouble(pkg["average_num_cores"]) ?? 0
            return Stats.CPUCluster(
                name: "P\(i)",
                freq: pkgFreqGHz(cores),
                load: avgNumCores / Double(perCoreLoad ? 1 : max(cores.count, 1)),
                number: cores.count
            )
        }

        return Stats(power: power, cpu: cpus)
    }

    struct Ansi {
        static let bright = "\u{001B}[1m"
        static let dim    = "\u{001B}[2m"
        static let magenta = "\u{001B}[35m"
        static let reset  = "\u{001B}[0m"
    }

    func printHeaders(stats: Stats, summary: Bool = false) {
        let padding = summary ? 19 : 5
        headersPrinted = true

        var cols: [String] = []
        if stats.power.cpu   != nil { cols.append("CPU") }
        if stats.power.gpu   != nil { cols.append("GPU") }
        if stats.power.total != nil { cols.append(summary ? "Total W" : "Tot W") }

        // печать первой части (жирной) с паддингом
        if !cols.isEmpty {
            let padded = cols.map {
                $0.padding(toLength: max(padding, $0.count), withPad: " ", startingAt: 0)
            }.joined(separator: " ")
            print(Ansi.bright + padded + Ansi.reset + " ", terminator: " ")
        }

        let names = stats.cpu.map { cluster -> String in
            if cluster.name.hasSuffix("-Cluster") {
                return String(cluster.name.dropLast(8))
            }
            return cluster.name
        }

        // "load, " + DIM "GHz"
        print("\(Ansi.bright)\(names.joined(separator: ", ")) load, \(Ansi.dim)GHz\(Ansi.reset)", terminator: "")
    }

    func printStats(_ stats: Stats) {
        var r = "\n"

        if let cpu = stats.power.cpu {
            r += String(format: "%5.2f ", cpu)
        }
        if let gpu = stats.power.gpu {
            r += String(format: "%5.2f ", gpu)
        }
        if let total = stats.power.total {
            r += "\(Ansi.magenta)\(String(format: "%5.2f", total))\(Ansi.reset) "
        }

        // load + freq для каждого кластера
        var parts: [String] = []
        for cl in stats.cpu {
            let loadStr = String(format: "%.0f%%", cl.load * 100.0)
            let freqStr = String(format: "%4.2f", cl.freq)
            parts.append("\(loadStr) \(Ansi.dim)\(freqStr)\(Ansi.reset) ")
        }

        print(r, parts.joined(), terminator: "")
        fflush(stdout)
    }
}


func main() {
    let lines = FileHandleLineSequence(handle: FileHandle.standardInput)
    let pruned = PrunedLineSequence(base: lines)
    let plists = PlistSequence(base: pruned)

    let printer = StatsPrinter(perCoreLoad: true)

    for plist in plists {
        if let proc = plist["processor"] as? [String : Any] {
            autoreleasepool {
                _ = printer.feed(proc)
            }
        }
    }
}

main()
