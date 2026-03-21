import AppKit
import Combine
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

struct MetricsSeriesDescriptor {
    let title: String
    let color: Color
    var lineWidth = 1.0
    let value: (Metrics) -> Double
    var usageValue: ((Metrics) -> Double)?
}

@MainActor
struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    let helpMarkdown: String?
    let schemaBuilder: (Metrics?) -> AnyHashable
    let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]
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
        schemaBuilder: { _ in "power" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "SYS",
                    color: MetricsChartPalette.board,
                    value: { Double($0.power.board) }
                ),
                MetricsSeriesDescriptor(
                    title: "CHIP",
                    color: MetricsChartPalette.package,
                    value: { Double($0.power.package) }
                ),
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    value: { Double($0.power.cpu) }
                ),
                MetricsSeriesDescriptor(
                    title: "ANE",
                    color: MetricsChartPalette.ane,
                    value: { Double($0.power.ane) }
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    value: { Double($0.power.gpu) }
                ),
            ]
        }
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
        schemaBuilder: { metrics in
            guard let metrics else { return AnyHashable("frequency.empty") }
            return AnyHashable(
                metrics.cpu_usage.map(\.name) + ["|"] + metrics.gpu_usage.map(\.name)
            )
        },
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        helpMarkdown: nil,
        schemaBuilder: { _ in "temperature" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    lineWidth: 2.0,
                    value: { Double($0.temperature.cpuAverage) }
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    lineWidth: 2.0,
                    value: { Double($0.temperature.gpuAverage) }
                ),
            ]
        }
    )

    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu_usage.enumerated().map { index, cluster in
            MetricsSeriesDescriptor(
                title: cluster.name,
                color: MetricsChartPalette.cpuFrequencyPalette[
                    index % MetricsChartPalette.cpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.cpu_usage[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.cpu_usage[index].usage)
                }
            )
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu_usage.enumerated().map { index, cluster in
            MetricsSeriesDescriptor(
                title: cluster.name,
                color: MetricsChartPalette.gpuFrequencyPalette[
                    index % MetricsChartPalette.gpuFrequencyPalette.count
                ],
                value: { metrics in
                    Double(metrics.gpu_usage[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    Double(metrics.gpu_usage[index].usage)
                }
            )
        }
    }
}


private struct PreparedMetricsSample {
    let sampleID: Int
    let schemaVersion: Int
    let lineValues: [Double]
    let fillValues: [Double?]
}

@MainActor
final class MetricsChartController {
    private(set) var data: LineChartData?
    private(set) var rightBoundary: Int = 0

    private var lastAppliedSampleID: Int?
    private var lastAppliedSchemaVersion: Int?
    private var lineDataSets: [LineChartDataSet] = []
    private var fillDataSets: [LineChartDataSet?] = []

    struct UpdateResult {
        let schemaChanged: Bool
        let appended: Bool
    }

    @discardableResult
    fileprivate func append(
        sample: PreparedMetricsSample,
        series: [MetricsSeriesDescriptor],
        capacity: Int
    ) -> UpdateResult {
        let schemaChanged = lastAppliedSchemaVersion != sample.schemaVersion || data == nil
        if schemaChanged {
            rebuildEmptyData(series: series)
            lastAppliedSchemaVersion = sample.schemaVersion
            lastAppliedSampleID = nil
        }

        guard lastAppliedSampleID != sample.sampleID else {
            rightBoundary = (lastAppliedSampleID ?? -1) + 1
            return UpdateResult(schemaChanged: schemaChanged, appended: false)
        }

        appendEntries(from: sample, series: series)
        trimToCapacity(capacity)

        lastAppliedSampleID = sample.sampleID
        rightBoundary = sample.sampleID + 1
        return UpdateResult(schemaChanged: schemaChanged, appended: true)
    }

    var rawYMax: Double {
        data?.getYMax(axis: .left) ?? 0
    }

    private func rebuildEmptyData(
        series: [MetricsSeriesDescriptor]
    ) {
        lineDataSets = series.map { descriptor in
            let dataSet = LineChartDataSet(entries: [], label: descriptor.title)
            dataSet.mode = .linear
            dataSet.drawValuesEnabled = false
            dataSet.drawCirclesEnabled = false
            dataSet.drawFilledEnabled = false
            dataSet.lineWidth = descriptor.lineWidth
            dataSet.setColor(NSColor(descriptor.color))
            dataSet.highlightEnabled = false
            return dataSet
        }

        fillDataSets = series.map { descriptor in
            guard descriptor.usageValue != nil else { return nil }

            let dataSet = LineChartDataSet(entries: [], label: descriptor.title)
            dataSet.mode = .linear
            dataSet.drawValuesEnabled = false
            dataSet.drawCirclesEnabled = false
            dataSet.lineWidth = 0
            dataSet.drawFilledEnabled = true
            dataSet.fillColor = NSColor(descriptor.color)
            dataSet.fillAlpha = 0.3
            dataSet.highlightEnabled = false
            return dataSet
        }

        data = LineChartData(dataSets: fillDataSets.compactMap { $0 } + lineDataSets.reversed())
    }

    private func appendEntries(
        from sample: PreparedMetricsSample,
        series: [MetricsSeriesDescriptor]
    ) {
        for (index, _) in series.enumerated() {
            lineDataSets[index].append(
                ChartDataEntry(x: Double(sample.sampleID), y: sample.lineValues[index])
            )

            guard let fillDataSet = fillDataSets[index],
                  let value = sample.fillValues[index] else {
                continue
            }

            fillDataSet.append(
                ChartDataEntry(x: Double(sample.sampleID), y: value)
            )
        }
    }

    private func trimToCapacity(_ capacity: Int) {
        guard capacity > 0 else { return }

        let trimThreshold = capacity * 2

        lineDataSets.forEach { dataSet in
            guard dataSet.count > trimThreshold else { return }
            dataSet.removeFirst(dataSet.count - capacity)
        }

        fillDataSets.forEach { dataSet in
            guard let dataSet else { return }
            guard dataSet.count > trimThreshold else { return }
            dataSet.removeFirst(dataSet.count - capacity)
        }
    }
}


@MainActor
final class MetricsChartStore: ObservableObject {
    @Published fileprivate var chartRevision = 0
    private(set) var latestMetrics: Metrics?
    private(set) var visibleSeries: [MetricsSeriesDescriptor] = []

    let controller = MetricsChartController()

    private var isUIEnabled = true

    private let definition: MetricsChartDefinition
    private let capacity: Int
    private var schema: AnyHashable?
    private var schemaVersion = 0
    private var appendedCount = 0
    private var metricsSubscription: AnyCancellable?

    init(
        definition: MetricsChartDefinition,
        metricsPublisher: AnyPublisher<Metrics, Never>,
        capacity: Int
    ) {
        self.definition = definition
        self.capacity = capacity
        self.metricsSubscription = metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.append(metrics)
            }
    }

    func setUIEnabled(_ isEnabled: Bool) {
        guard isUIEnabled != isEnabled else { return }
        isUIEnabled = isEnabled

        if isEnabled {
            chartRevision += 1
        }
    }

    private func append(_ metrics: Metrics) {
        let newSchema = definition.schemaBuilder(metrics)
        if schema != newSchema {
            visibleSeries = definition.seriesBuilder(metrics)
            schema = newSchema
            schemaVersion += 1
        }

        let preparedSample = PreparedMetricsSample(
            sampleID: appendedCount,
            schemaVersion: schemaVersion,
            lineValues: visibleSeries.map { descriptor in
                descriptor.value(metrics)
            },
            fillValues: visibleSeries.map { descriptor in
                guard let usageValue = descriptor.usageValue else { return nil }
                return usageValue(metrics) * descriptor.value(metrics)
            }
        )

        appendedCount += 1
        controller.append(
            sample: preparedSample,
            series: visibleSeries,
            capacity: capacity
        )
        latestMetrics = metrics
        if isUIEnabled {
            chartRevision += 1
        }
    }
}

final class UpperBoundStabilizer {
    private(set) var current: Double = -.infinity

    /// If the new quantized value is sufficiently below the current bound,
    /// the upper bound is allowed to shrink.
    let shrinkThreshold: Double

    /// Allowed significand steps in the [1, 10] decade.
    /// Example: with [1, 1.5, 2, 3, 5, 10],
    /// 112 -> 150, 0.112 -> 0.15, -112 -> -100, -0.112 -> -0.1.
    let steps: [Double]

    let spaceTop: Double

    init(shrinkThreshold: Double, steps: [Double], spaceTop: Double = 0.0) {
        self.shrinkThreshold = shrinkThreshold
        self.steps = steps
        self.spaceTop = spaceTop
    }

    func reset() {
        current = -.infinity
    }

    func update(height: Double) -> Double {
        guard height > 0 else { return 0 }

        let newHeight = quantizeUp(height * (1 + spaceTop))

        if newHeight > current || newHeight < current * shrinkThreshold {
            current = newHeight
        }

        return current
    }

    private func quantizeUp(_ value: Double) -> Double {
        guard value > 0 else { return 0 }

        let exponent = floor(log10(value))
        let scale = pow(10.0, exponent)
        let significand = value / scale
        let quantizedSignificand = steps.first(where: { $0 >= significand }) ?? 10

        return quantizedSignificand * scale
    }
}



private final class MetricsCurrentValuesRenderer: LineChartRenderer {
    struct Row {
        let valueText: String
        let valueColor: NSColor
        let usageText: String?
    }

    var rows: [Row] = []

    override func drawExtras(context: CGContext) {
        super.drawExtras(context: context)
        drawLatestValues(context: context)
    }

    private func drawLatestValues(context: CGContext) {
        guard !rows.isEmpty else { return }

        let fontSize: CGFloat = 10
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
        ]
        let usageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let leftX = viewPortHandler.contentRight
        let valueTopPadding: CGFloat = 4

        let measuredRows: [(value: NSAttributedString, valueSize: CGSize, usage: NSAttributedString?, usageSize: CGSize)] = rows.map { row in
            let value = NSAttributedString(
                string: row.valueText,
                attributes: valueAttributes.merging([
                    .foregroundColor: row.valueColor,
                ]) { _, new in new }
            )
            let valueSize = value.size()

            let usage = row.usageText.map {
                NSAttributedString(string: $0, attributes: usageAttributes)
            }
            let usageSize = usage?.size() ?? .zero

            return (value, valueSize, usage, usageSize)
        }

        let totalHeight = measuredRows.reduce(CGFloat.zero) { partial, row in
            partial + valueTopPadding + row.valueSize.height + row.usageSize.height
        }
        var currentY = viewPortHandler.contentBottom - totalHeight

        for row in measuredRows {
            currentY += valueTopPadding
            row.value.draw(at: CGPoint(x: leftX, y: currentY))
            currentY += row.valueSize.height

            if let usage = row.usage {
                usage.draw(at: CGPoint(x: leftX, y: currentY))
                currentY += row.usageSize.height
            }
        }
    }
}

final class MetricsLineChartView: LineChartView {
    let yMaxStabilizer = UpperBoundStabilizer(
        shrinkThreshold: 0.6,
        steps: [1, 1.5, 2.5, 4, 6, 10],
        spaceTop: 0.1
    )

    fileprivate var currentValueRows: [MetricsCurrentValuesRenderer.Row] = [] {
        didSet {
            (renderer as? MetricsCurrentValuesRenderer)?.rows = currentValueRows
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installCurrentValuesRenderer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installCurrentValuesRenderer()
    }

    private func installCurrentValuesRenderer() {
        let renderer = MetricsCurrentValuesRenderer(
            dataProvider: self,
            animator: chartAnimator,
            viewPortHandler: viewPortHandler
        )
        renderer.rows = currentValueRows
        self.renderer = renderer
    }

    func refreshUI() {
        data?.notifyDataChanged()
        notifyDataSetChanged()
    }
}

private struct MetricsDGChartView: NSViewRepresentable {
    let controller: MetricsChartController
    let revision: Int
    let series: [MetricsSeriesDescriptor]
    let metrics: Metrics
    let capacity: Int
    let yStart: Double
    let desiredCount: Int
    let valueFormatter: (Double) -> String
    let usageValueFormatter: ((Double) -> String)?

    func makeNSView(context: Context) -> MetricsLineChartView {
        let chartView = MetricsLineChartView()
        chartView.drawBordersEnabled = false
        chartView.drawGridBackgroundEnabled = false
        chartView.chartDescription.enabled = false
        chartView.scaleXEnabled = false
        chartView.scaleYEnabled = false
        chartView.minOffset = 0
        chartView.extraTopOffset = 8
        chartView.extraRightOffset = 40
        chartView.currentValueRows = makeCurrentValueRows()

        let xAxis = chartView.xAxis
        xAxis.enabled = true
        xAxis.drawLabelsEnabled = false
        xAxis.drawAxisLineEnabled = false
        xAxis.drawGridLinesEnabled = false

        let rightAxis = chartView.rightAxis
        rightAxis.enabled = false
        return chartView
    }

    func updateNSView(_ chartView: MetricsLineChartView, context: Context) {
        if chartView.data !== controller.data {
            chartView.data = controller.data
            chartView.yMaxStabilizer.reset()
        }

        chartView.currentValueRows = makeCurrentValueRows()

        configureLegend(chartView)
        configureAxes(chartView)
        chartView.refreshUI()
    }

    private func makeCurrentValueRows() -> [MetricsCurrentValuesRenderer.Row] {
        series.map { descriptor in
            MetricsCurrentValuesRenderer.Row(
                valueText: valueFormatter(descriptor.value(metrics)),
                valueColor: NSColor(descriptor.color),
                usageText: {
                    guard let usageValueFormatter,
                          let usageValue = descriptor.usageValue else {
                        return nil
                    }
                    return usageValueFormatter(usageValue(metrics))
                }()
            )
        }
    }

    private func configureAxes(_ chartView: MetricsLineChartView) {
        let xAxis = chartView.xAxis
        xAxis.axisMinimum = Double(controller.rightBoundary - capacity)
        xAxis.axisMaximum = Double(controller.rightBoundary)

        let leftAxis = chartView.leftAxis
        leftAxis.enabled = true
        leftAxis.axisMinimum = yStart
        leftAxis.axisMaximum = getYMax(chartView)

        leftAxis.drawLabelsEnabled = true
        leftAxis.setLabelCount(desiredCount, force: false)
        leftAxis.drawAxisLineEnabled = false
        leftAxis.drawGridLinesEnabled = true
        leftAxis.gridLineWidth = 0.2
        leftAxis.gridLineDashLengths = [3, 2]
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 1
        leftAxis.zeroLineDashLengths = nil
    }

    private func getYMax(_ chartView: MetricsLineChartView) -> Double {
        chartView.yMaxStabilizer.update(height: controller.rawYMax - yStart) + yStart
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
        legend.setCustom(entries: series.map { descriptor in
            let entry = LegendEntry(label: descriptor.title)
            entry.formColor = NSColor(descriptor.color)
            return entry
        })
    }
}

struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let capacity: Int
    let isVisible: Bool
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)? = nil
    var desiredCount = 6
    var yStart = 0.0
    @StateObject private var store: MetricsChartStore
    @State private var isHelpPresented = false

    init(
        definition: MetricsChartDefinition,
        metricsPublisher: AnyPublisher<Metrics, Never>,
        capacity: Int,
        isVisible: Bool,
        valueFormatter: @escaping (Double) -> String,
        usageValueFormatter: ((Double) -> String)? = nil,
        desiredCount: Int = 6,
        yStart: Double = 0.0
    ) {
        self.definition = definition
        self.capacity = capacity
        self.isVisible = isVisible
        self.valueFormatter = valueFormatter
        self.usageValueFormatter = usageValueFormatter
        self.desiredCount = desiredCount
        self.yStart = yStart
        _store = StateObject(
            wrappedValue: MetricsChartStore(
                definition: definition,
                metricsPublisher: metricsPublisher,
                capacity: capacity
            )
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let lastMetrics = store.latestMetrics {
                MetricsDGChartView(
                    controller: store.controller,
                    revision: store.chartRevision,
                    series: store.visibleSeries,
                    metrics: lastMetrics,
                    capacity: capacity,
                    yStart: yStart,
                    desiredCount: desiredCount,
                    valueFormatter: valueFormatter,
                    usageValueFormatter: usageValueFormatter
                )
            } else {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .topLeading, content: headerView)
        .onAppear {
            store.setUIEnabled(isVisible)
        }
        .onChange(of: isVisible) { _, newValue in
            store.setUIEnabled(newValue)
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
