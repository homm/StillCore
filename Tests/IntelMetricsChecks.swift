import Foundation

@main
struct IntelMetricsChecks {
    static func main() throws {
        let processor: [String: Any] = [
            "package_watts": 12.5,
            "packages": [
                ["average_num_cores": 1.5, "cores": [
                    ["cpus": [["freq_hz": 2_000_000_000.0]]],
                    ["cpus": [["freq_hz": 3_000_000_000.0]]],
                ]],
                ["average_num_cores": 0.5, "cores": [
                    ["cpus": [["freq_hz": 1_500_000_000.0]]],
                ]],
            ],
        ]
        let sample = try PropertyListSerialization.data(
            fromPropertyList: ["processor": processor], format: .xml, options: 0
        )
        var parser = IntelMetricsParser()
        let split = sample.count / 3
        precondition(parser.append(Data(sample[..<split])).isEmpty)
        precondition(parser.append(Data(sample[split..<(split * 2)])).isEmpty)
        let first = parser.append(Data(sample[(split * 2)...]))
        precondition(first.count == 1)
        precondition(first[0].power.package == 12.5)
        precondition(first[0].cpu_usage.map(\.frequencyMHz) == [2_500, 1_500])
        precondition(first[0].cpu_usage.map(\.usage) == [0.75, 0.5])
        precondition(first[0].cpu_usage.map(\.units) == [2, 1])

        var noPower = processor
        noPower.removeValue(forKey: "package_watts")
        let missingPowerSample = try PropertyListSerialization.data(
            fromPropertyList: ["processor": noPower], format: .xml, options: 0
        )
        precondition(IntelMetricsParser.parse(missingPowerSample)?.power.package == nil)

        let bad = Data("<?xml version=\"1.0\"?><plist><broken></plist>".utf8)
        precondition(parser.append(bad + sample).count == 1)
        precondition(IntelMetricsParser.parse(bad) == nil)
        let incomplete = Data(sample.dropLast(10))
        precondition(IntelMetricsParser.parse(incomplete) == nil)
        precondition(IntelMetricsParser.parse(Data("garbage".utf8)) == nil)
        print("PASS: Intel plist stream, package values, malformed and incomplete samples")
    }
}
