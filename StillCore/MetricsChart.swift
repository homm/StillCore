import AppKit
import SwiftUI
import DGCharts
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
            MetricsSeriesDescriptor(
                id: "cpu-frequency-\(index)",
                title: cluster.name,
                color: MetricsChartPalette.cpuFrequencyPalette[
                    index % MetricsChartPalette.cpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.cpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.cpu[index].usage)
                }
            )
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu.enumerated().map { index, cluster in
            MetricsSeriesDescriptor(
                id: "gpu-frequency-\(index)",
                title: cluster.name,
                color: MetricsChartPalette.gpuFrequencyPalette[
                    index % MetricsChartPalette.gpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.gpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.gpu[index].usage)
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

private struct MetricsChartRenderSeries: Identifiable {
    struct Point {
        let x: Double
        let y: Double
    }

    let id: String
    let title: String
    let color: NSColor
    let linePoints: [Point]
    let fillPoints: [Point]?
}

private extension MetricsChartRenderSeries {
    var lineEntries: [ChartDataEntry] {
        linePoints.map { ChartDataEntry(x: $0.x, y: $0.y) }
    }

    var fillEntries: [ChartDataEntry]? {
        fillPoints?.map { ChartDataEntry(x: $0.x, y: $0.y) }
    }
}

private extension Color {
    var metricsNSColor: NSColor {
        NSColor(self)
    }
}

private struct MetricsChartRenderModel {
    let series: [MetricsChartRenderSeries]

    init(samples: [MetricsSample], series descriptors: [MetricsSeriesDescriptor]) {
        self.series = descriptors.map { descriptor in
            let linePoints = samples.map { sample in
                MetricsChartRenderSeries.Point(
                    x: Double(sample.sampleID),
                    y: descriptor.value(sample.metrics)
                )
            }

            let fillPoints = descriptor.usageValue.map { usageValue in
                samples.map { sample in
                    MetricsChartRenderSeries.Point(
                        x: Double(sample.sampleID),
                        y: usageValue(sample.metrics) * descriptor.value(sample.metrics)
                    )
                }
            }

            return MetricsChartRenderSeries(
                id: descriptor.id,
                title: descriptor.title,
                color: descriptor.color.metricsNSColor,
                linePoints: linePoints,
                fillPoints: fillPoints
            )
        }
    }
}

private struct MetricsChartLegendItem: Identifiable {
    let id: String
    let title: String
    let color: NSColor
}

private struct MetricsDGChartView: NSViewRepresentable {
    let renderModel: MetricsChartRenderModel
    let xDomain: ClosedRange<Int>
    let yStart: Double
    let desiredCount: Int
    let lineWidth: Double

    func makeNSView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.drawBordersEnabled = false
        chartView.drawGridBackgroundEnabled = false
        chartView.chartDescription.enabled = false
        chartView.scaleXEnabled = false
        chartView.scaleYEnabled = false
        chartView.minOffset = 0
        chartView.extraTopOffset = 8

        let xAxis = chartView.xAxis
        xAxis.enabled = true
        xAxis.drawLabelsEnabled = false
        xAxis.drawAxisLineEnabled = false
        xAxis.drawGridLinesEnabled = false

        let rightAxis = chartView.rightAxis
        rightAxis.enabled = false
        return chartView
    }

    func updateNSView(_ chartView: LineChartView, context: Context) {
        configureAxes(chartView)
        configureLegend(chartView)
        chartView.data = makeChartData()
    }

    private func configureAxes(_ chartView: LineChartView) {
        let xAxis = chartView.xAxis
        xAxis.axisMinimum = Double(xDomain.lowerBound)
        xAxis.axisMaximum = Double(xDomain.upperBound)


        let leftAxis = chartView.leftAxis
        leftAxis.enabled = true
        leftAxis.axisMinimum = yStart
        leftAxis.axisMaximum = getYMax(chartView)
        leftAxis.spaceTop = 0.05

        leftAxis.drawLabelsEnabled = true
        leftAxis.setLabelCount(desiredCount, force: false)
        leftAxis.drawAxisLineEnabled = false
        leftAxis.drawGridLinesEnabled = true
        leftAxis.gridLineWidth = 0.5
        leftAxis.gridLineDashLengths = [3, 2]
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 1
        leftAxis.zeroLineDashLengths = nil
    }

    private func getYMax(_ chartView: LineChartView) -> Double {
        let rawYMax = chartView.data?.getYMax(axis: .left) ?? 0
        return pow(ceil(pow(rawYMax, 1.0 / 1.5)), 1.5)
    }

    private func makeChartData() -> LineChartData {
        let fillDataSets = renderModel.series.compactMap(makeFillDataSet(for:))
        let lineDataSets = renderModel.series.reversed().map(makeLineDataSet(for:))
        return LineChartData(dataSets: fillDataSets + lineDataSets)
    }

    private func makeLineDataSet(for series: MetricsChartRenderSeries) -> LineChartDataSet {
        let dataSet = LineChartDataSet(entries: series.lineEntries, label: series.title)
        dataSet.mode = .linear
        dataSet.drawValuesEnabled = false
        dataSet.drawCirclesEnabled = false
        dataSet.drawFilledEnabled = false
        dataSet.lineWidth = lineWidth
        dataSet.setColor(series.color)
        dataSet.highlightEnabled = false
        return dataSet
    }

    private func makeFillDataSet(for series: MetricsChartRenderSeries) -> LineChartDataSet? {
        guard let fillEntries = series.fillEntries else { return nil }

        let dataSet = LineChartDataSet(entries: fillEntries, label: series.title)
        dataSet.mode = .linear
        dataSet.drawValuesEnabled = false
        dataSet.drawCirclesEnabled = false
        dataSet.lineWidth = 0
        dataSet.drawFilledEnabled = true
        dataSet.fillColor = series.color
        dataSet.fillAlpha = 0.3
        dataSet.setColor(series.color)
        dataSet.highlightEnabled = false
        return dataSet
    }

    private func configureLegend(_ chartView: LineChartView) {
        let legend = chartView.legend
        legend.enabled = true
        legend.horizontalAlignment = .right
        legend.verticalAlignment = .top
        legend.orientation = .horizontal
        legend.drawInside = false
        legend.form = .circle
        legend.formSize = 8
        legend.xEntrySpace = 10
        legend.xOffset = 0
        legend.yOffset = -1
        legend.font = .systemFont(ofSize: 12)
        legend.textColor = NSColor(Color.secondary)
        legend.setCustom(entries: renderModel.series.map { series in
            let entry = LegendEntry(label: series.title)
            entry.formColor = series.color
            return entry
        })
    }
}

struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let samples: [MetricsSample]
    let latestMetrics: Metrics?
    let xDomain: ClosedRange<Int>
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)? = nil
    var desiredCount = 6
    var lineWidth = 1.0
    var yStart = 0.0
    @State private var isHelpPresented = false

    private var resolvedSeries: [MetricsSeriesDescriptor] {
        definition.resolvedSeries(from: latestMetrics ?? samples.last?.metrics)
    }

    private var renderModel: MetricsChartRenderModel {
        MetricsChartRenderModel(samples: samples, series: resolvedSeries)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if samples.isEmpty {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MetricsDGChartView(
                    renderModel: renderModel,
                    xDomain: xDomain,
                    yStart: yStart,
                    desiredCount: desiredCount,
                    lineWidth: lineWidth
                )
                if let latestMetrics {
                    latestValuesView(metrics: latestMetrics)
                }
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .topLeading, content: headerView)
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
                .font(.system(size: 12, design: .monospaced))
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
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}
