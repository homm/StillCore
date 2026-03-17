import AppKit
import SwiftUI
import Charts
import MacmonSwift

private enum MetricsChartPalette {
    static let board = Color(red: 0.12, green: 0.8, blue: 0.2)
    static let package = Color(red: 0.13, green: 0.48, blue: 0.97)
    static let cpu = Color(red: 0.32, green: 0.74, blue: 0.98)
    static let gpu = Color(red: 1, green: 0.22, blue: 0.02)
    static let ane = Color(red: 0.98, green: 0.58, blue: 0.02)

    static let cpuFrequencyPalette: [Color] = [
        board, package, cpu,
        Color(red: 0.18, green: 0.60, blue: 0.84),
        Color(red: 0.10, green: 0.42, blue: 0.70),
    ]

    static let gpuFrequencyPalette: [Color] = [
        gpu, ane,
        Color(red: 0.92, green: 0.36, blue: 0.18),
        Color(red: 0.86, green: 0.14, blue: 0.34),
    ]
}

func normalizedGPUClusterName(_ rawName: String) -> String {
    rawName.isEmpty ? "" : rawName.uppercased()
}

struct MetricsSeriesDescriptor: Identifiable {
    let id: String
    let title: String
    let color: Color
    let value: (Metrics) -> Double
    var usageValue: ((Metrics) -> Double)?
}

struct MetricsSample: Identifiable {
    let sampleID: Int
    let metrics: Metrics

    var id: Int { sampleID }
}

@MainActor
struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    let helpMarkdown: String?
    private let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]

    init(title: String, unitLabel: String, helpMarkdown: String? = nil, series: [MetricsSeriesDescriptor]) {
        self.title = title
        self.unitLabel = unitLabel
        self.helpMarkdown = helpMarkdown
        self.seriesBuilder = { _ in series }
    }

    init(
        title: String,
        unitLabel: String,
        helpMarkdown: String? = nil,
        seriesBuilder: @escaping (Metrics?) -> [MetricsSeriesDescriptor]
    ) {
        self.title = title
        self.unitLabel = unitLabel
        self.helpMarkdown = helpMarkdown
        self.seriesBuilder = seriesBuilder
    }

    func resolvedSeries(from metrics: Metrics?) -> [MetricsSeriesDescriptor] {
        seriesBuilder(metrics)
    }
}

@MainActor
enum MetricsChartDefinitions {
    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "WATT",
        helpMarkdown:
"""
**Power draw by components**

• `SYS` is the total system power draw.
• `CHIP` is the power reported for the whole SoC, including all compute units and memory.
• `CPU`, `GPU`, and `ANE` are individual parts of `CHIP`.
""",
        series: [
            MetricsSeriesDescriptor(
                id: "sys",
                title: "SYS",
                color: MetricsChartPalette.board,
                value: { Double($0.power.board) }
            ),
            MetricsSeriesDescriptor(
                id: "chip",
                title: "CHIP",
                color: MetricsChartPalette.package,
                value: { Double($0.power.package) }
            ),
            MetricsSeriesDescriptor(
                id: "cpu",
                title: "CPU",
                color: MetricsChartPalette.cpu,
                value: { Double($0.power.cpu) }
            ),
            MetricsSeriesDescriptor(
                id: "ane",
                title: "ANE",
                color: MetricsChartPalette.ane,
                value: { Double($0.power.ane) }
            ),
            MetricsSeriesDescriptor(
                id: "gpu",
                title: "GPU",
                color: MetricsChartPalette.gpu,
                value: { Double($0.power.gpu) }
            ),
        ]
    )

    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage",
        unitLabel: "GHz",
        helpMarkdown:
"""
Current frequency and usage of all CPU and GPU clusters.

**How to read this mess**
Each cluster is shown with a solid line for frequency \
and a semi-transparent area underneath for current usage. \
The area shows the fraction of that frequency that is being used. \
When usage is at 100%, the area reaches the line.
""",
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        series: [
            MetricsSeriesDescriptor(
                id: "cpu-average",
                title: "CPU AVG",
                color: MetricsChartPalette.cpu,
                value: { Double($0.temperature.cpuAverage) }
            ),
            MetricsSeriesDescriptor(
                id: "gpu-average",
                title: "GPU AVG",
                color: MetricsChartPalette.gpu,
                value: { Double($0.temperature.gpuAverage) }
            ),
        ]
    )
    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu.enumerated().map { index, cluster in
            return MetricsSeriesDescriptor(
                id: "cpu-frequency-\(index)",
                title: cluster.name,
                color: MetricsChartPalette.cpuFrequencyPalette[
                    index % MetricsChartPalette.cpuFrequencyPalette.count],
                value: { metrics in
                    return Double(metrics.cpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    return Double(metrics.cpu[index].usage)
                }
            )
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu.enumerated().map { index, cluster in
            return MetricsSeriesDescriptor(
                id: "gpu-frequency-\(index)",
                title: cluster.name,
                color: MetricsChartPalette.gpuFrequencyPalette[
                    index % MetricsChartPalette.gpuFrequencyPalette.count],
                value: { metrics in
                    return Double(metrics.gpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    return Double(metrics.gpu[index].usage)
                }
            )
        }
    }

    private static func frequencyTitle(
        prefix: String,
        rawName: String,
        fallbackIndex: Int,
        normalizedName: (String) -> String
    ) -> String {
        let normalized = normalizedName(rawName)
        if normalized.isEmpty {
            return "\(prefix) \(fallbackIndex + 1)"
        }
        return "\(prefix) \(normalized)"
    }
}

private extension View {
    @ViewBuilder
    func chartYScaleIfPresent(_ domain: ClosedRange<Double>?) -> some View {
        if let domain {
            self.chartYScale(domain: domain)
        } else {
            self
        }
    }
}

struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let samples: [MetricsSample]
    let latestMetrics: Metrics?
    let xDomain: ClosedRange<Int>
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)? = nil
    var desiredCount = 7
    var lineWidth = 1.0
    var yScaleDomain: ClosedRange<Double>? = nil
    @State private var isHelpPresented = false

    private var resolvedSeries: [MetricsSeriesDescriptor] {
        definition.resolvedSeries(from: latestMetrics ?? samples.last?.metrics)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if samples.isEmpty {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                chartView
                if let latestMetrics {
                    latestValuesView(metrics: latestMetrics)
                }
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .topLeading, content: headerView)
    }

    private var chartView: some View {
        Chart {
            ForEach(resolvedSeries) { series in
                if let usageValue = series.usageValue {
                    ForEach(samples, id: \.id) { sample in
                        AreaMark(
                            x: .value("Sample", sample.sampleID),
                            yStart: .value("Usage Base", 0),
                            yEnd: .value(
                                "Usage", usageValue(sample.metrics) * series.value(sample.metrics)),
                        )
                        .foregroundStyle(by: .value("Series", series.title))
                        .opacity(0.3)
                        .interpolationMethod(.linear)
                    }
                }
            }

            ForEach(resolvedSeries.reversed()) { series in
                ForEach(samples, id: \.id) { sample in
                    LineMark(
                        x: .value("Sample", sample.sampleID),
                        y: .value("Value", series.value(sample.metrics)),
                    )
                    .foregroundStyle(by: .value("Series", series.title))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: resolvedSeries.map(\.title),
            range: resolvedSeries.map(\.color)
        )
        .chartLegend(position: .top, alignment: .trailing, spacing: 10)
        .chartXScale(domain: xDomain)
        .chartYScaleIfPresent(yScaleDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: desiredCount)) { value in
                AxisGridLine(
                    stroke: value.as(Double.self) == 0
                        ? StrokeStyle(lineWidth: 1)
                        : StrokeStyle(lineWidth: 0.5, dash: [3, 2])
                )
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
    }

    private func latestValuesView(metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(resolvedSeries) { series in
                Text(valueFormatter(series.value(metrics)))
                    .font(.system(.footnote, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(series.color)
                if let usageValueFormatter, let usageValue = series.usageValue {
                    Text(usageValueFormatter(usageValue(metrics)))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func headerView() -> some View {
        HStack(alignment: .bottom) {
            HStack(alignment: .center, spacing: 4) {
                Text(definition.title)
                    .font(.headline)
                if let helpMarkdown = definition.helpMarkdown {
                    Button {
                        isHelpPresented.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
                        ChartHelpPopover(markdown: helpMarkdown)
                    }
                }
            }
            Spacer()
            Text(definition.unitLabel)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChartHelpPopover: View {
    let markdown: String

    private var attributedMarkdown: AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(markdown)
        }
    }

    var body: some View {
        Text(attributedMarkdown)
            .font(.system(.callout))
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}
