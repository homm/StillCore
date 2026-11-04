import AppKit
import DGCharts

enum MetricsCurrentValuesLayout {
    static let valuesColumnWidth: CGFloat = 42
    static let labelsColumnWidth: CGFloat = 28
    static let columnSpacing: CGFloat = 4

    static var rightOffset: CGFloat {
        valuesColumnWidth + columnSpacing + labelsColumnWidth
    }
}

final class MetricsCurrentValuesRenderer: LineChartRenderer {
    private var currentValuesHeight: CGFloat?
    private var lineHeights: [CGFloat] = []

    override func drawFilledPath(context: CGContext, path: CGPath, fillColor: NSColor, fillAlpha: CGFloat) {
        context.saveGState()
        if fillColor.alphaComponent < 1 {
            context.setBlendMode(.overlay)
        }
        super.drawFilledPath(context: context, path: path, fillColor: fillColor, fillAlpha: fillAlpha)
        context.restoreGState()
    }

    func resetCurrentValuesLayout() {
        currentValuesHeight = nil
        lineHeights = []
    }

    func currentValuesRow(at point: CGPoint) -> MetricsDetailsBuilder.Row? {
        guard let chartView = dataProvider as? MetricsLineChartView else { return nil }
        let rows = MainActor.assumeIsolated {
            MetricsDetailsBuilder.buildRows(
                from: chartView.getMaterializedPointsSlice(),
                series: chartView.series
            )
        }
        let textHeight = currentValuesHeight ?? lineHeights.reduce(0, +)
        guard !rows.isEmpty,
              !lineHeights.isEmpty,
              point.x >= viewPortHandler.contentRight
        else {
            return nil
        }

        let baseY = viewPortHandler.contentBottom - textHeight
        guard point.y >= baseY, point.y <= viewPortHandler.contentBottom else {
            return nil
        }

        var y = baseY
        var lineIndex = 0

        for row in rows {
            let rowStartY = y

            for _ in row.items {
                guard lineHeights.indices.contains(lineIndex) else { return nil }
                y += lineHeights[lineIndex]
                lineIndex += 1
            }

            if point.y >= rowStartY, point.y <= y {
                return row
            }
        }

        return nil
    }

    override func drawExtras(context: CGContext) {
        super.drawExtras(context: context)
        guard let chartView = dataProvider as? MetricsLineChartView else { return }
        let rows = MainActor.assumeIsolated {
            MetricsDetailsBuilder.buildRows(
                from: chartView.getMaterializedPointsSlice(),
                series: chartView.series
            )
        }
        let hiddenDescriptors = MainActor.assumeIsolated { chartView.hiddenDescriptors }
        drawLatestValues(rows: rows, hiddenDescriptors: hiddenDescriptors)
    }

    private func drawLatestValues(
        rows: [MetricsDetailsBuilder.Row],
        hiddenDescriptors: Set<Int>
    ) {
        let overlap: CGFloat = 8
        let valueLines = MetricsDetailsTextBuilder.buildValueLines(
            from: rows,
            hiddenDescriptors: hiddenDescriptors
        )
        let labelLines = MetricsDetailsTextBuilder.buildLabelLines(
            from: rows,
            hiddenDescriptors: hiddenDescriptors
        )
        guard !valueLines.isEmpty else {
            return
        }

        let textHeight: CGFloat
        if let currentValuesHeight, lineHeights.count == valueLines.count {
            textHeight = currentValuesHeight
        } else {
            lineHeights = measureLinesHeight(for: valueLines)
            textHeight = lineHeights.reduce(0, +)
            currentValuesHeight = textHeight
        }

        var y = viewPortHandler.contentBottom - textHeight
        let valuesX = viewPortHandler.contentRight - overlap
        let labelsX = viewPortHandler.contentRight + MetricsCurrentValuesLayout.valuesColumnWidth
            + MetricsCurrentValuesLayout.columnSpacing

        for ((valueLine, labelLine), height) in zip(zip(valueLines, labelLines), lineHeights) {
            valueLine.draw(
                with: CGRect(
                    x: valuesX,
                    y: y,
                    width: MetricsCurrentValuesLayout.valuesColumnWidth + overlap,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            labelLine.draw(
                with: CGRect(
                    x: labelsX,
                    y: y,
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            y += height
        }
    }

    private func measureLinesHeight(for valueLines: [NSAttributedString]) -> [CGFloat] {
        let unconstrainedSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        return valueLines.map { line in
            let lineHeight = line.boundingRect(
                with: unconstrainedSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            let style = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            return lineHeight + (style?.paragraphSpacing ?? 0)
        }
    }
}

enum MetricsDetailsBuilder {
    struct Row {
        struct Item {
            let descriptorIndex: Int
            let text: String
            let color: NSColor
            let label: String?
        }

        let items: [Item]
    }

    @MainActor
    static func buildRows(
        from slice: [MaterializedChartPoint],
        series: [MetricsSeriesDescriptor]
    ) -> [Row] {
        let sortedSlice = slice.sorted { lhs, rhs in
            lhs.descriptorIndex < rhs.descriptorIndex
        }

        var rows: [Row] = []
        var currentGroup: String?
        var currentItems: [Row.Item] = []

        func flushCurrentRow() {
            guard !currentItems.isEmpty else { return }
            rows.append(.init(items: currentItems))
            currentItems = []
        }

        for point in sortedSlice {
            guard series.indices.contains(point.descriptorIndex) else { continue }
            let descriptor = series[point.descriptorIndex]
            guard descriptor.showsDetails else { continue }

            let group = descriptor.detailsGroup ?? "__details_\(point.descriptorIndex)"
            if currentGroup != group {
                flushCurrentRow()
                currentGroup = group
            }

            let itemColor: NSColor = switch descriptor.kind {
            case .line:
                descriptor.color
            case .fill:
                descriptor.color.withAlphaComponent(max(descriptor.color.alphaComponent, 0.6))
            }

            currentItems.append(
                .init(
                    descriptorIndex: point.descriptorIndex,
                    text: descriptor.detailsFormatter(point.detailsValue),
                    color: descriptor.textColor ?? itemColor,
                    label: currentItems.isEmpty ? descriptor.title : nil
                )
            )
        }

        flushCurrentRow()
        return rows
    }
}

enum MetricsDetailsTextBuilder {
    private static let rowSpacing: CGFloat = 4
    private static let hiddenTextAlpha: CGFloat = 0.5

    private static func valueFont(for fontSize: CGFloat) -> NSFont {
        switch fontSize {
        case 12:
            AppFonts.chartDetailsValue
        case 10:
            AppFonts.chartDetailsMarkerValue
        default:
            AppFonts.tabularSystemFont(ofSize: fontSize, weight: .bold)
        }
    }

    static func buildLabelLines(
        from rows: [MetricsDetailsBuilder.Row],
        hiddenDescriptors: Set<Int> = []
    ) -> [NSAttributedString] {
        rows.enumerated().flatMap { rowIndex, row in
            row.items.enumerated().map { itemIndex, item in
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .left
                if itemIndex == row.items.indices.last,
                   rowIndex < rows.indices.last ?? 0 {
                    paragraphStyle.paragraphSpacing = rowSpacing
                }
                let color = hiddenDescriptors.contains(item.descriptorIndex)
                    ? item.color.withAlphaComponent(hiddenTextAlpha)
                    : item.color
                return NSAttributedString(
                    string: item.label ?? "",
                    attributes: [
                        .font: AppFonts.chartLegend,
                        .foregroundColor: color,
                        .paragraphStyle: paragraphStyle,
                    ]
                )
            }
        }
    }

    static func buildValueLines(
        from rows: [MetricsDetailsBuilder.Row],
        hiddenDescriptors: Set<Int> = [],
        fontSize: CGFloat = 12,
        trailingNewline: Bool = false
    ) -> [NSAttributedString] {
        let font = valueFont(for: fontSize)
        let percentFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        return rows.enumerated().flatMap { rowIndex, row in
            row.items.enumerated().map { itemIndex, item in
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .right
                if itemIndex == row.items.indices.last,
                   rowIndex < rows.indices.last ?? 0 {
                    paragraphStyle.paragraphSpacing = rowSpacing
                }
                let color = hiddenDescriptors.contains(item.descriptorIndex)
                    ? item.color.withAlphaComponent(hiddenTextAlpha)
                    : item.color
                let line = NSMutableAttributedString(
                    string: trailingNewline ? item.text + "\n" : item.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: paragraphStyle,
                    ]
                )
                let nsLine = item.text as NSString
                if nsLine.hasSuffix("%") {
                    let percentRange = NSRange(location: nsLine.length - 1, length: 1)
                    line.addAttribute(.font, value: percentFont, range: percentRange)
                }
                return line
            }
        }
    }

}

class FormattedTextMarkerView: MarkerView {
    var attributedText = NSAttributedString() {
        didSet {
            updateLayout()
        }
    }

    private let contentInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    private let cornerRadius: CGFloat = 4
    private let markerSpacing: CGFloat = 4

    private func updateLayout() {
        guard attributedText.length > 0 else {
            frame.size = .zero
            return
        }

        let textBounds = attributedText.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let size = CGSize(
            width: contentInsets.left + textBounds.width + contentInsets.right,
            height: contentInsets.top + textBounds.height + contentInsets.bottom
        )

        frame.size = size
        offset = CGPoint(x: -size.width - markerSpacing, y: -size.height / 2)
    }

    override func draw(context: CGContext, point: CGPoint) {
        guard attributedText.length > 0 else { return }

        let offset = offsetForDrawing(atPoint: point)
        let rect = CGRect(
            x: point.x + offset.x,
            y: point.y + offset.y,
            width: bounds.width,
            height: bounds.height
        )

        context.saveGState()

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let textRect = CGRect(
            x: rect.minX + contentInsets.left,
            y: rect.minY + contentInsets.top,
            width: rect.width - contentInsets.left - contentInsets.right,
            height: rect.height - contentInsets.top - contentInsets.bottom
        )
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        context.restoreGState()
    }
}

private extension NSAttributedString {
    var removingTrailingNewline: NSAttributedString {
        guard string.hasSuffix("\n"), length > 0 else { return self }
        return attributedSubstring(from: NSRange(location: 0, length: length - 1))
    }
}

final class MetricsDetailsMarkerView: FormattedTextMarkerView {
    var showsSampleTime = false

    private static let relativeDateFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter
    }()

    private func buildTimeText(from sampleDate: Date) -> NSAttributedString {
        let elapsed = max(0, Int(Date().timeIntervalSince(sampleDate)))
        let timeText = Self.relativeDateFormatter.string(from: TimeInterval(elapsed)) ?? "\(elapsed)s"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        paragraphStyle.paragraphSpacing = 4
        return NSAttributedString(
            string: "-\(timeText)\n",
            attributes: [
                .font: AppFonts.chartLegend,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    @MainActor
    override func refreshContent(entry: ChartDataEntry, highlight: Highlight) {
        guard let chartView = chartView as? MetricsLineChartView else {
            attributedText = NSAttributedString()
            return
        }

        let points = chartView.getMaterializedPointsSlice(x: entry.x)
        let rows = MetricsDetailsBuilder.buildRows(
            from: points,
            series: chartView.series
        )
        let text = NSMutableAttributedString()

        if showsSampleTime,
           let sampleDate = (entry.data as? MaterializedChartPoint)?.sampleDate ?? points.first?.sampleDate {
            text.append(buildTimeText(from: sampleDate))
        }

        for line in MetricsDetailsTextBuilder.buildValueLines(from: rows, fontSize: 10, trailingNewline: true) {
            text.append(line)
        }
        attributedText = text.removingTrailingNewline
    }
}
