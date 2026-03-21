import AppKit
import Combine
import SwiftUI
import DGCharts
import MacmonSwift

struct MetricsSeriesDescriptor {
    let title: String
    let color: Color
    var lineWidth = 1.0
    let value: (Metrics) -> Double
    var usageValue: ((Metrics) -> Double)?
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)?

    func formattedValue(for metrics: Metrics) -> String {
        valueFormatter(value(metrics))
    }

    func formattedUsageValue(for metrics: Metrics) -> String? {
        guard let usageValue = usageValue,
              let usageValueFormatter = usageValueFormatter else {
            return nil
        }
        return usageValueFormatter(usageValue(metrics))
    }
}

@MainActor
struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    let helpMarkdown: String?
    let schemaBuilder: (Metrics?) -> AnyHashable
    let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]
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

    private var lastAppliedSchemaVersion: Int?
    private var lineDataSets: [LineChartDataSet] = []
    private var fillDataSets: [LineChartDataSet?] = []

    struct UpdateResult {
        let schemaChanged: Bool
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
        }

        appendEntries(from: sample, series: series)
        trimToCapacity(capacity)
        updateSinglePointAppearance(series: series)

        rightBoundary = sample.sampleID
        return UpdateResult(schemaChanged: schemaChanged)
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
            dataSet.drawCircleHoleEnabled = false
            dataSet.drawFilledEnabled = false
            dataSet.lineWidth = descriptor.lineWidth
            dataSet.circleRadius = descriptor.lineWidth
            dataSet.setColor(NSColor(descriptor.color))
            dataSet.setCircleColor(NSColor(descriptor.color))
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

    private func updateSinglePointAppearance(series: [MetricsSeriesDescriptor]) {
        for dataSet in lineDataSets {
            dataSet.drawCirclesEnabled = dataSet.count == 1
        }
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

    private var showUpdates = true

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

    func setShowUpdates(_ showUpdates: Bool) {
        guard self.showUpdates != showUpdates else { return }
        self.showUpdates = showUpdates

        if showUpdates {
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
        if showUpdates {
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
        var currentY = viewPortHandler.contentBottom - totalHeight + 4

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
        shrinkThreshold: 0.7,
        steps: [1, 1.5, 2, 3, 4, 5, 6, 8, 10],
        spaceTop: 0.05
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

    func refreshData() {
        data?.notifyDataChanged()
    }
}

private struct MetricsDGChartView: NSViewRepresentable {
    let controller: MetricsChartController
    let series: [MetricsSeriesDescriptor]
    let metrics: Metrics
    let capacity: Int
    let yStart: Double
    let yAxisLabelCount: Int

    func makeNSView(context: Context) -> MetricsLineChartView {
        let chartView = MetricsLineChartView()
        chartView.drawBordersEnabled = false
        chartView.drawGridBackgroundEnabled = false
        chartView.chartDescription.enabled = false
        chartView.scaleXEnabled = false
        chartView.scaleYEnabled = false
        chartView.minOffset = 0
        chartView.extraTopOffset = 8
        chartView.extraBottomOffset = 4
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
        chartView.refreshData()

        configureLegend(chartView)
        configureAxes(chartView)
        chartView.notifyDataSetChanged()
    }

    private func makeCurrentValueRows() -> [MetricsCurrentValuesRenderer.Row] {
        series.map { descriptor in
            MetricsCurrentValuesRenderer.Row(
                valueText: descriptor.formattedValue(for: metrics),
                valueColor: NSColor(descriptor.color),
                usageText: descriptor.formattedUsageValue(for: metrics)
            )
        }
    }

    private func configureAxes(_ chartView: MetricsLineChartView) {
        let xAxis = chartView.xAxis
        xAxis.axisMinimum = Double(controller.rightBoundary - capacity)
        // Visual compensation for drawing outside of edge
        xAxis.axisMaximum = Double(controller.rightBoundary) + 0.1

        let leftAxis = chartView.leftAxis
        leftAxis.enabled = true
        leftAxis.axisMinimum = yStart
        leftAxis.axisMaximum = getYMax(chartView)

        leftAxis.drawLabelsEnabled = true
        leftAxis.setLabelCount(yAxisLabelCount, force: false)
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
    let showUpdates: Bool
    let yAxisLabelCount: Int
    let yStart: Double
    // The chart store owns the long-lived chart data/controller state for this section.
    // It must be created once per section instance and survive SwiftUI body recomputation.
    @StateObject private var store: MetricsChartStore
    @State private var isHelpPresented = false

    // The section initializer receives the chart definition and the shared metrics stream,
    // then creates a persistent store instance that subscribes to that stream exactly once.
    init(
        definition: MetricsChartDefinition,
        metricsPublisher: AnyPublisher<Metrics, Never>,
        capacity: Int,
        showUpdates: Bool,
        yAxisLabelCount: Int = 5,
        yStart: Double = 0.0
    ) {
        self.definition = definition
        self.capacity = capacity
        self.showUpdates = showUpdates
        self.yAxisLabelCount = yAxisLabelCount
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
                    series: store.visibleSeries,
                    metrics: lastMetrics,
                    capacity: capacity,
                    yStart: yStart,
                    yAxisLabelCount: yAxisLabelCount
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
            store.setShowUpdates(showUpdates)
        }
        .onChange(of: showUpdates) { _, newValue in
            store.setShowUpdates(newValue)
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
