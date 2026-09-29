import Foundation

// The chart and status item use the same sample shape in both app targets.
struct Metrics: Sendable {
    struct Power: Sendable {
        let package: Double?
    }

    struct CPUCluster: Sendable {
        let name: String
        let frequencyMHz: UInt32
        let usage: Double
        let units: Int
    }

    let power: Power
    let cpu_usage: [CPUCluster]
}

struct IntelMetricsParser {
    private static let closingTag = Data("</plist>".utf8)
    private static let openingTag = Data("<?xml".utf8)
    private var buffer = Data()
    private let maxSampleBytes = 16 * 1024 * 1024

    mutating func append(_ chunk: Data) -> [Metrics] {
        buffer.append(chunk)
        var result: [Metrics] = []
        while let range = buffer.range(of: Self.closingTag) {
            let candidate = Data(buffer[..<range.upperBound])
            buffer.removeSubrange(..<range.upperBound)
            let sample: Data
            if let opening = candidate.range(of: Self.openingTag, options: .backwards) {
                sample = Data(candidate[opening.lowerBound...])
            } else {
                sample = candidate
            }
            if let metrics = Self.parse(sample) {
                result.append(metrics)
            }
        }
        if buffer.count > maxSampleBytes {
            buffer.removeAll(keepingCapacity: true)
        }
        return result
    }

    static func parse(_ data: Data) -> Metrics? {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            return nil
        }
        if let document = plist as? [String: Any],
           let processor = document["processor"] as? [String: Any] {
            return convert(processor)
        }
        return nil
    }

    private static func convert(_ processor: [String: Any]) -> Metrics? {
        if let packages = processor["packages"] as? [[String: Any]] {
            let clusters = packages.enumerated().compactMap { index, package -> Metrics.CPUCluster? in
                if let cores = package["cores"] as? [[String: Any]], !cores.isEmpty {
                    let frequencies = cores.flatMap { core in
                        (core["cpus"] as? [[String: Any]] ?? []).compactMap { number($0["freq_hz"]) }
                    }
                    let frequency = frequencies.isEmpty ? 0 : frequencies.reduce(0, +) / Double(frequencies.count)
                    let activeCores = number(package["average_num_cores"]) ?? 0
                    return .init(
                        name: "P\(index)",
                        frequencyMHz: UInt32(max(0, min(Double(UInt32.max), frequency / 1_000_000))),
                        usage: max(0, min(1, activeCores / Double(cores.count))),
                        units: cores.count
                    )
                }
                return nil
            }
            if !clusters.isEmpty {
                return Metrics(
                    power: .init(package: number(processor["package_watts"])),
                    cpu_usage: clusters
                )
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}
