import SwiftUI
import AppKit

struct BatteryStatusLabel: View {
    let state: BatteryRuntimeState?
    let trackerRunning: Bool
    @State private var isBatteryUsagePresented = false

    var body: some View {
        if let state {
            batteryStatusButton(state)
        } else {
            Text("Battery status unavailable")
        }
    }

    private func batteryStatusButton(_ state: BatteryRuntimeState) -> some View {
        let battery = state.batteryStatus
        let status: String = switch state.chargeStatus {
        case .charging: "Charging"
        case .onHold: "On Hold"
        case .charged: "Charged"
        case .discharging: "On Battery"
        }
        var title = status
        var footer = status
        var suffix = ""
        var times: [(String, String)] = []
        let (remaining, full) = if let remaining = battery.remainingCapacity, let full = battery.fullChargeCapacity, full > 0 {
            (remaining, full)
        } else {
            (battery.currentCapacityMah, battery.maxCapacityMah)
        }
        var charges = [("Remaining charge", "\(remaining.formatted()) / \(full.formatted()) mAh")]

        if !battery.isOnACPower, trackerRunning,
           let session = state.batteryTrackerState?.session {
            if let activeSeconds = state.activeSeconds {
                let activeTime = formatDuration(activeSeconds)
                times = [("Active time", activeTime), ("Sleep time", formatDuration(session.sleepSeconds))]
                if let usedPercent = state.usedPercent {
                    title = "Drained \(Int(usedPercent.rounded()))%"
                    footer = "\(title) over \(activeTime)"
                    suffix = " since last charge"
                }
            }
            let start = session.startChargeMah ?? session.startCapacityMah
            let unit = state.usedCapacityMah == nil ? "%" : " mAh"
            charges.append(("Initial charge", "\(start.formatted())\(unit)"))
        }

        return Button(footer) { isBatteryUsagePresented.toggle() }
            .buttonStyle(AccessoryLikeButtonStyle())
            .fixedSize()
            .popover(isPresented: $isBatteryUsagePresented, arrowEdge: .bottom) {
                BatteryStatusSummary(title: title, suffix: suffix, groups: [times, charges])
                    .fixedSize()
                    .padding(12)
            }
            .padding(.leading, -3)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct BatteryStatusSummary: NSViewRepresentable {
    let title: String
    let suffix: String
    let groups: [[(label: String, value: String)]]

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isRichText = false
        view.isEditable = false
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let summary = attributedText
        if let storage = view.textStorage, !storage.isEqual(to: summary) {
            let selection = view.selectedRange()
            let wasAllSelected = selection.length > 0 && selection.length == storage.length
            storage.setAttributedString(summary)
            let end = NSMaxRange(selection)
            let start = min(selection.location, storage.length)
            let newEnd = wasAllSelected ? storage.length : min(end, storage.length)
            view.setSelectedRange(NSRange(location: start, length: newEnd - start))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        nsView.attributedString().size()
    }

    private var attributedText: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString(string: title, attributes: bold)
        result.append(NSAttributedString(string: suffix, attributes: normal))

        let width = groups.joined().map { ("\($0.label):" as NSString).size(withAttributes: label).width }.max() ?? 0
        let valueColumn = NSTextTab(textAlignment: .left, location: ceil(width) + 8)
        for group in groups {
            for (index, row) in group.enumerated() {
                result.append(NSAttributedString(string: "\n", attributes: normal))
                let start = result.length
                result.append(NSAttributedString(string: "\(row.label):\t", attributes: label))
                result.append(NSAttributedString(string: row.value, attributes: normal))
                let style = NSMutableParagraphStyle()
                style.tabStops = [valueColumn]
                style.paragraphSpacingBefore = index == 0 ? 8 : 3
                result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: result.length - start))
            }
        }
        return result
    }
}
