import SwiftUI
import AppKit

struct BatteryDrainSummary: NSViewRepresentable {
    let percent: Int
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
        let result = NSMutableAttributedString(string: "Drained \(percent)%", attributes: bold)
        result.append(NSAttributedString(string: " since last charge", attributes: normal))

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
