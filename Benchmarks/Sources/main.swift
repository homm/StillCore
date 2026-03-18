import Benchmark
import Charts
import Foundation
import SwiftUI


private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

BenchmarkColumn.register(
    BenchmarkColumn(
        name: "throughput",
        value: { 1 / median($0.measurements) },
        unit: .inverseTime,
    )
)

benchmark("Charts.LineMark.InitOnly") {
    _ = LineMark(
        x: .value("Sample", 99),
        y: .value("Watts", 13.5)
    )
}

benchmark("Charts.LineMark.StyledFragment") {
    _ = LineMark(
        x: .value("Sample", 99),
        y: .value("Watts", 13.5)
    )
        .foregroundStyle(by: .value("Series", "GPU"))
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: 1))
}

Benchmark.main()
