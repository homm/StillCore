import AppKit
import Combine
import SwiftUI
import DGCharts
#if !STILLCORE_INTEL
import MacmonSwift
#endif

struct MetricsSeriesDescriptor {
    enum Kind {
        case line
        case fill
    }

    let title: String
    let color: NSColor
    let kind: Kind
    var lineWidth = 1.0
    let chartValue: (Metrics) -> Double
    var detailsValue: ((Metrics) -> Double)?
    let detailsFormatter: (Double) -> String
    var detailsGroup: String?
    var showsDetails = true
}

@MainActor
struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    let helpMarkdown: String?
    var showsSampleTime = false
    let schemaBuilder: (Metrics?) -> AnyHashable
    let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]
}


private struct MaterializedMetricsSample {
    struct SeriesValue {
        let chartValue: Double
        let detailsValue: Double
    }

    let sampleID: Int
    let sampleDate: Date
    let values: [SeriesValue]
}

struct MaterializedChartPoint {
    let descriptorIndex: Int
    let detailsValue: Double
    let sampleDate: Date
}

@MainActor
final class ChartDataController {
    private(set) var data: LineChartData?
    private(set) var series: [MetricsSeriesDescriptor] = []
    private(set) var rightBoundary: Int = 0

    private var schema: AnyHashable?
    private var appendedCount = 0
    private var dataSets: [LineChartDataSet] = []
    private var seriesKinds: [MetricsSeriesDescriptor.Kind] = []

    struct UpdateResult {
        let schemaChanged: Bool
    }

    @discardableResult
    fileprivate func append(
        metrics: Metrics,
        definition: MetricsChartDefinition,
        capacity: Int
    ) -> UpdateResult {
        let newSchema = definition.schemaBuilder(metrics)
        let schemaChanged = schema != newSchema || data == nil
        if schemaChanged {
            series = definition.seriesBuilder(metrics)
            schema = newSchema
            rebuildEmptyData(series: series)
        }

        let sample = MaterializedMetricsSample(
            sampleID: appendedCount,
            sampleDate: Date(),
            values: series.map { descriptor in
                let chartValue = descriptor.chartValue(metrics)
                return .init(
                    chartValue: chartValue,
                    detailsValue: descriptor.detailsValue?(metrics) ?? chartValue
                )
            }
        )

        appendEntries(from: sample, series: series)
        trimToCapacity(capacity)
        updateSinglePointAppearance(series: series)

        rightBoundary = sample.sampleID
        appendedCount += 1
        return UpdateResult(schemaChanged: schemaChanged)
    }

    private func rebuildEmptyData(
        series: [MetricsSeriesDescriptor]
    ) {
        seriesKinds = series.map(\.kind)
        dataSets = series.map { descriptor in
            let dataSet = LineChartDataSet(entries: [], label: descriptor.title)
            dataSet.mode = .linear
            dataSet.drawValuesEnabled = false
            dataSet.drawCirclesEnabled = false

            switch descriptor.kind {
            case .line:
                dataSet.highlightEnabled = true
                dataSet.drawHorizontalHighlightIndicatorEnabled = false
                dataSet.drawCircleHoleEnabled = false
                dataSet.drawFilledEnabled = false
                dataSet.lineWidth = descriptor.lineWidth
                dataSet.circleRadius = descriptor.lineWidth
                dataSet.setColor(descriptor.color)
                dataSet.setCircleColor(descriptor.color)
            case .fill:
                dataSet.highlightEnabled = false
                dataSet.lineWidth = 0
                dataSet.drawFilledEnabled = true
                dataSet.fillColor = descriptor.color
                dataSet.fillAlpha = 1.0
            }

            return dataSet
        }

        let fillDataSets = zip(seriesKinds, dataSets)
            .compactMap { kind, dataSet in
                kind == .fill ? dataSet : nil
            }
        let lineDataSets = zip(seriesKinds, dataSets)
            .compactMap { kind, dataSet in
                kind == .line ? dataSet : nil
            }

        data = LineChartData(dataSets: fillDataSets + lineDataSets.reversed())
    }

    private func updateSinglePointAppearance(series: [MetricsSeriesDescriptor]) {
        for (kind, dataSet) in zip(seriesKinds, dataSets) {
            guard kind == .line else { continue }
            dataSet.drawCirclesEnabled = dataSet.count == 1
        }
    }

    private func appendEntries(
        from sample: MaterializedMetricsSample,
        series: [MetricsSeriesDescriptor]
    ) {
        for (index, _) in series.enumerated() {
            dataSets[index].append(
                ChartDataEntry(
                    x: Double(sample.sampleID),
                    y: sample.values[index].chartValue,
                    data: MaterializedChartPoint(
                        descriptorIndex: index,
                        detailsValue: sample.values[index].detailsValue,
                        sampleDate: sample.sampleDate
                    )
                )
            )
        }
    }

    private func trimToCapacity(_ capacity: Int) {
        guard capacity > 0 else { return }

        let trimThreshold = capacity * 2

        dataSets.forEach { dataSet in
            guard dataSet.count > trimThreshold else { return }
            // Keep one extra historical sample so the marker can disappear cleanly
            // when the viewport shrinks past the previously highlighted point.
            dataSet.removeFirst(dataSet.count - capacity - 1)
        }
    }

    func clearHistory() {
        dataSets.forEach { dataSet in
            dataSet.removeFirst(max(0, dataSet.count - 1))
        }
        updateSinglePointAppearance(series: series)
    }

    func visibleYMax(fromX: Double, toX: Double, fallback: Double) -> Double {
        var yMax = fallback

        for dataSet in dataSets where dataSet.isVisible {
            for entry in dataSet.entries where entry.x >= fromX && entry.x <= toX {
                yMax = max(yMax, entry.y)
            }
        }

        return yMax
    }
}


@MainActor
final class MetricsChartStore: ObservableObject {
    @Published fileprivate var chartRevision = 0

    let controller = ChartDataController()

    private var showUpdates = true

    private let definition: MetricsChartDefinition
    private let capacity: Int
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

    func clearHistory() {
        controller.clearHistory()
        chartRevision += 1
    }

    private func append(_ metrics: Metrics) {
        controller.append(
            metrics: metrics,
            definition: definition,
            capacity: capacity
        )
        if showUpdates {
            chartRevision += 1
        }
    }
}

final class UpperBoundStabilizer {
    private(set) var current: Double = -.infinity
    private let clock = ContinuousClock()
    private let retentionDuration: Duration = .seconds(10)
    private var lastVisibleHeight: Double?
    private var retainedOffscreenHeight: Double?
    private var retainedOffscreenExpiresAt: ContinuousClock.Instant?

    /// If the new quantized value is sufficiently below the current bound,
    /// the upper bound is allowed to shrink.
    let shrinkThreshold: Double

    /// Allowed significant steps in the [1, 10] decade.
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
        lastVisibleHeight = nil
        retainedOffscreenHeight = nil
        retainedOffscreenExpiresAt = nil
    }

    func update(height: Double) -> Double {
        let now = clock.now
        expireRetainedHeightIfNeeded(now: now)

        if let lastVisibleHeight, height < lastVisibleHeight {
            let candidateRetainedHeight = lastVisibleHeight

            if candidateRetainedHeight > (retainedOffscreenHeight ?? 0) {
                retainedOffscreenHeight = candidateRetainedHeight
                retainedOffscreenExpiresAt = now.advanced(by: retentionDuration)
            }
        }

        self.lastVisibleHeight = height

        let effectiveHeight = max(height, retainedOffscreenHeight ?? 0)
        guard effectiveHeight > 0 else { return 0 }

        let newHeight = quantizeUp(effectiveHeight * (1 + spaceTop))

        if newHeight > current || newHeight < current * shrinkThreshold {
            current = newHeight
        }

        return current
    }

    private func expireRetainedHeightIfNeeded(now: ContinuousClock.Instant) {
        guard let retainedOffscreenExpiresAt else { return }
        guard retainedOffscreenExpiresAt <= now else { return }

        retainedOffscreenHeight = nil
        self.retainedOffscreenExpiresAt = nil
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


final class MetricsLineChartView: LineChartView {
    let yMaxStabilizer = UpperBoundStabilizer(
        shrinkThreshold: 0.7,
        steps: [1, 1.5, 2, 3, 4, 5, 6, 8, 10],
        spaceTop: 0.05
    )
    var yMaxResetRevision = 0
    var series: [MetricsSeriesDescriptor] = []
    var clearHighlight: (() -> Void)?
    var onCurrentValuesRowMouseDown: ((MetricsDetailsBuilder.Row, Bool) -> Void)?
    var hiddenDescriptors: Set<Int> = []
    nonisolated(unsafe) private var currentValuesMouseDownMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.renderer = MetricsCurrentValuesRenderer(
            dataProvider: self,
            animator: chartAnimator,
            viewPortHandler: viewPortHandler
        )
        let marker = MetricsDetailsMarkerView()
        marker.chartView = self
        self.marker = marker
        currentValuesMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window
            else {
                return event
            }

            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point),
                  let renderer = self.renderer as? MetricsCurrentValuesRenderer,
                  let row = renderer.currentValuesRow(at: point)
            else {
                return event
            }

            self.onCurrentValuesRowMouseDown?(row, event.modifierFlags.contains(.shift))
            return nil
        }
    }

    deinit {
        if let currentValuesMouseDownMonitor {
            NSEvent.removeMonitor(currentValuesMouseDownMonitor)
        }
    }

    func resetCurrentValuesLayout() {
        (renderer as? MetricsCurrentValuesRenderer)?.resetCurrentValuesLayout()
    }

    func applyCurrentValuesVisibility() {
        guard let data else { return }

        for case let dataSet as LineChartDataSet in data.dataSets {
            guard let point = dataSet.first?.data as? MaterializedChartPoint,
                  series.indices.contains(point.descriptorIndex)
            else {
                continue
            }

            dataSet.visible = !hiddenDescriptors.contains(point.descriptorIndex)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        clearHighlight?()
    }

    override func getMarkerPosition(highlight: Highlight) -> CGPoint {
        CGPoint(
            x: highlight.drawX,
            y: viewPortHandler.contentTop + viewPortHandler.contentHeight / 2
        )
    }

    @MainActor
    func getMaterializedPointsSlice(x: Double? = nil) -> [MaterializedChartPoint] {
        guard let data else { return [] }
        var slice: [MaterializedChartPoint] = []

        for case let dataSet as LineChartDataSet in data.dataSets {
            let x = x ?? dataSet.last?.x
            guard let x else { continue }

            for entry in dataSet.entriesForXValue(x) {
                guard let point = entry.data as? MaterializedChartPoint else { continue }
                slice.append(point)
            }
        }

        return slice
    }

    func applySharedHighlight(_ sampleX: Double?) {
        guard highlighted.first?.x != sampleX || (sampleX == nil && !highlighted.isEmpty) else { return }

        highlightValue(sampleX.flatMap(makeHighlight), callDelegate: false)
    }

    private func makeHighlight(for sampleX: Double) -> Highlight? {
        guard let data else { return nil }

        for dataSetIndex in data.dataSets.indices {
            guard let dataSet = data.dataSets[dataSetIndex] as? LineChartDataSet,
                  dataSet.highlightEnabled,
                  let entry = dataSet.entryForXValue(sampleX, closestToY: Double.nan)
            else {
                continue
            }

            guard entry.x == sampleX else { continue }
            return Highlight(x: entry.x, y: entry.y, dataSetIndex: dataSetIndex)
        }

        return nil
    }
}

private struct MetricsDGChartView: NSViewRepresentable {
    let controller: ChartDataController
    let revision: Int
    let capacity: Int
    let yMaxResetRevision: Int
    let yStart: Double
    let yAxisLabelCount: Int
    let showsSampleTime: Bool
    let settingsInvalidationKey: AnyHashable
    @Binding var highlightedSampleX: Double?

    final class Coordinator: NSObject, ChartViewDelegate {
        private let highlightedSampleX: Binding<Double?>

        init(highlightedSampleX: Binding<Double?>) {
            self.highlightedSampleX = highlightedSampleX
        }

        nonisolated
        func chartValueSelected(
            _ chartView: ChartViewBase,
            entry: ChartDataEntry,
            highlight: Highlight
        ) {
            let sampleX = entry.x
            Task { @MainActor [highlightedSampleX] in highlightedSampleX.wrappedValue = sampleX }
        }

        nonisolated
        func chartValueNothingSelected(_ chartView: ChartViewBase) {
            Task { @MainActor [highlightedSampleX] in highlightedSampleX.wrappedValue = nil }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(highlightedSampleX: $highlightedSampleX)
    }

    func makeNSView(context: Context) -> MetricsLineChartView {
        let chartView = MetricsLineChartView()
        (chartView.marker as? MetricsDetailsMarkerView)?.showsSampleTime = showsSampleTime
        chartView.drawBordersEnabled = false
        chartView.drawGridBackgroundEnabled = false
        chartView.chartDescription.enabled = false
        chartView.drawMarkers = true
        chartView.highlightPerTapEnabled = true
        chartView.scaleXEnabled = false
        chartView.scaleYEnabled = false
        chartView.minOffset = 0
        chartView.extraTopOffset = 8
        chartView.extraBottomOffset = 4
        chartView.extraRightOffset = MetricsCurrentValuesLayout.rightOffset
        chartView.clearHighlight = { highlightedSampleX = nil }
        chartView.onCurrentValuesRowMouseDown = { row, isShiftPressed in
            let rowDescriptors = Set(row.items.map(\.descriptorIndex))
            let allDescriptors = Set(
                chartView.series.enumerated().compactMap { index, descriptor in
                    descriptor.showsDetails ? index : nil
                }
            )
            let otherDescriptors = allDescriptors.subtracting(rowDescriptors)

            if isShiftPressed {
                chartView.hiddenDescriptors = otherDescriptors
            } else if chartView.hiddenDescriptors == otherDescriptors {
                chartView.hiddenDescriptors = rowDescriptors
            } else {
                let isHidden = row.items.allSatisfy { chartView.hiddenDescriptors.contains($0.descriptorIndex) }
                if isHidden {
                    for item in row.items {
                        chartView.hiddenDescriptors.remove(item.descriptorIndex)
                    }
                } else {
                    for item in row.items {
                        chartView.hiddenDescriptors.insert(item.descriptorIndex)
                    }
                }
            }

            chartView.applyCurrentValuesVisibility()
            chartView.resetCurrentValuesLayout()
            chartView.yMaxStabilizer.reset()
            configureAxisRanges(chartView)
            chartView.notifyDataSetChanged()
        }
        chartView.delegate = context.coordinator

        let xAxis = chartView.xAxis
        xAxis.enabled = true
        xAxis.drawLabelsEnabled = false
        xAxis.drawAxisLineEnabled = false
        xAxis.drawGridLinesEnabled = false

        let rightAxis = chartView.rightAxis
        rightAxis.enabled = false

        // Compensate sloppy clipping
        let legend = chartView.legend
        legend.enabled = true
        legend.horizontalAlignment = .right
        legend.verticalAlignment = .top
        legend.yOffset = -1
        legend.font = AppFonts.chartLegend
        legend.setCustom(entries: [LegendEntry(label: "")])

        return chartView
    }

    func updateNSView(_ chartView: MetricsLineChartView, context: Context) {
        if chartView.data !== controller.data {
            chartView.data = controller.data
            chartView.yMaxStabilizer.reset()
            chartView.resetCurrentValuesLayout()
            chartView.series = controller.series
            chartView.hiddenDescriptors.removeAll()
            configureAxes(chartView)
        }

        if chartView.yMaxResetRevision != yMaxResetRevision {
            chartView.yMaxResetRevision = yMaxResetRevision
            chartView.yMaxStabilizer.reset()
        }

        chartView.data?.notifyDataChanged()

        configureAxisRanges(chartView)
        chartView.notifyDataSetChanged()
        chartView.applySharedHighlight(highlightedSampleX)
    }

    private func configureAxes(_ chartView: MetricsLineChartView) {
        let xAxis = chartView.xAxis
        xAxis.enabled = true
        xAxis.drawLabelsEnabled = false
        xAxis.drawAxisLineEnabled = false
        xAxis.drawGridLinesEnabled = false

        let leftAxis = chartView.leftAxis
        leftAxis.enabled = true
        leftAxis.drawLabelsEnabled = true
        leftAxis.setLabelCount(yAxisLabelCount, force: false)
        leftAxis.drawAxisLineEnabled = false
        leftAxis.drawGridLinesEnabled = true
        leftAxis.gridLineWidth = 0.2
        leftAxis.gridLineDashLengths = [3, 2]
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 0.5
        leftAxis.zeroLineDashLengths = nil
    }

    private func configureAxisRanges(_ chartView: MetricsLineChartView) {
        let visibleMinX = Double(controller.rightBoundary - capacity + 1)
        let visibleMaxX = Double(controller.rightBoundary)

        chartView.xAxis.axisMinimum = visibleMinX
        // Visual compensation for drawing outside of edge
        chartView.xAxis.axisMaximum = visibleMaxX + 0.1

        let rawVisibleYMax = controller.visibleYMax(
            fromX: visibleMinX,
            toX: visibleMaxX,
            fallback: yStart
        )
        let visibleHeight = max(0, rawVisibleYMax - yStart)
        chartView.leftAxis.axisMinimum = yStart
        chartView.leftAxis.axisMaximum =
            chartView.yMaxStabilizer.update(height: visibleHeight) + yStart
    }

}

struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let capacity: Int
    let showUpdates: Bool
    let historyResetRevision: Int
    @Binding var highlightedSampleX: Double?
    let yAxisLabelCount: Int
    let yStart: Double
    let settingsInvalidationKey: AnyHashable
    private let settingsView: AnyView?
    // The chart store owns the long-lived chart data/controller state for this section.
    // It must be created once per section instance and survive SwiftUI body recomputation.
    @StateObject private var store: MetricsChartStore
    @State private var isHelpPresented = false
    @State private var isSettingsPresented = false
    @State private var yMaxResetRevision = 0

    // The section initializer receives the chart definition and the shared metrics stream,
    // then creates a persistent store instance that subscribes to that stream exactly once.
    init(
        definition: MetricsChartDefinition,
        metricsPublisher: AnyPublisher<Metrics, Never>,
        capacity: Int,
        showUpdates: Bool,
        historyResetRevision: Int,
        highlightedSampleX: Binding<Double?>,
        yAxisLabelCount: Int = 5,
        yStart: Double = 0.0,
        settingsInvalidationKey: AnyHashable = AnyHashable(0),
        settingsView: AnyView? = nil
    ) {
        self.definition = definition
        self.capacity = capacity
        self.showUpdates = showUpdates
        self.historyResetRevision = historyResetRevision
        self._highlightedSampleX = highlightedSampleX
        self.yAxisLabelCount = yAxisLabelCount
        self.yStart = yStart
        self.settingsInvalidationKey = settingsInvalidationKey
        self.settingsView = settingsView
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
            if store.controller.data != nil {
                MetricsDGChartView(
                    controller: store.controller,
                    revision: store.chartRevision,
                    capacity: capacity,
                    yMaxResetRevision: yMaxResetRevision,
                    yStart: yStart,
                    yAxisLabelCount: yAxisLabelCount,
                    showsSampleTime: definition.showsSampleTime,
                    settingsInvalidationKey: settingsInvalidationKey,
                    highlightedSampleX: $highlightedSampleX
                )
            } else {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(AppFonts.systemMessage)
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
            if showUpdates {
                yMaxResetRevision += 1
            }
        }
        .onChange(of: showUpdates) { _, newValue in
            store.setShowUpdates(newValue)
            if newValue {
                yMaxResetRevision += 1
            }
        }
        .onChange(of: historyResetRevision) { _, _ in
            highlightedSampleX = nil
            store.clearHistory()
            yMaxResetRevision += 1
        }
    }

    private func headerView() -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Spacer()
            Text(definition.title)
                .font(.headline)
            if let helpMarkdown = definition.helpMarkdown {
                Button {
                    isHelpPresented.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(AppFonts.helpIcon)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isHelpPresented, arrowEdge: .trailing) {
                    ChartHelpPopover(markdown: helpMarkdown)
                }
            }
            if let settingsView {
                Button {
                    isSettingsPresented.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(AppFonts.helpIcon)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isSettingsPresented, arrowEdge: .trailing) {
                    settingsView
                }
            }
            HStack(spacing: 3) {
                Text(definition.unitLabel)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
                .frame(
                    width: MetricsCurrentValuesLayout.valuesColumnWidth +
                        MetricsCurrentValuesLayout.labelsColumnWidth,
                    alignment: .leading
                )
        }
    }
}

private struct ChartHelpPopover: View {
    let markdown: String

    private var attributedMarkdown: AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
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
