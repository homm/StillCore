import SwiftUI

struct LogTextView: NSViewRepresentable {
    /// Вернуть координатор наружу (чтобы писать в него и/или менять capacity)
    var onReady: (Coordinator) -> Void

    final class Coordinator {
        let textView: NSTextView
        private(set) var lineCount: Int = 0
        private var capacity: Int = 1000   // единственный источник правды
        
        private var lastTimeShown: String = ""
        private static let sepParagraph: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byClipping
            p.alignment = .center
            return p
        }()
        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = .autoupdatingCurrent
            f.dateFormat = "HH:mm"
            return f
        }()

        init(textView: NSTextView) {
            self.textView = textView
            lastTimeShown = Self.timeFormatter.string(from: Date())
        }

        // Меняем лимит строк; сразу подрезаем лишнее, если уже превышен
        func setCapacity(_ newValue: Int) {
            capacity = max(0, newValue)
            while lineCount > capacity { dropFirstLine() }
        }

        // Построчное добавление без пересборки всего текста
        func appendLine(_ line: String) {
            guard !line.isEmpty else { return }
            let shouldAutoscroll = isAtBottom(threshold: 4)

            appendMinuteSeparatorIfNeeded()

            let s = textView.string.isEmpty ? line : "\n" + line
            textView.textStorage?.append(attributedFromANSI(s))

            lineCount += 1
            while lineCount > capacity { dropFirstLine() }
            
            if shouldAutoscroll {
                scrollVerticallyToBottom()
            }
        }

        func clear() {
            textView.string = ""
            lineCount = 0
        }

        func scrollVerticallyToBottom() {
            guard let scrollView = textView.enclosingScrollView else { return }
            let clip = scrollView.contentView

            // Обновляем лейаут, чтобы знать реальную высоту контента
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)

            // Сохраняем текущий X, меняем только Y
            let currentX = textView.visibleRect.minX
            clip.setBoundsOrigin(NSPoint(x: currentX, y: textView.bounds.height))
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: - Внутренние утилиты

        private func appendMinuteSeparatorIfNeeded(now: Date = Date()) {
            let hhmm = Self.timeFormatter.string(from: now)
            guard lastTimeShown != hhmm else { return }
            lastTimeShown = hhmm

            let line = NSAttributedString(
                string: "\n      \(hhmm)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor:NSColor.secondaryLabelColor,
                    .paragraphStyle: Self.sepParagraph
                ]
            )
            textView.textStorage?.append(line)
            lineCount += 1
        }

        private func isAtBottom(threshold: CGFloat = 0) -> Bool {
            return textView.visibleRect.maxY >= textView.bounds.height - threshold
        }

        private func dropFirstLine() {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let s = storage.string as NSString
            let nl = s.range(of: "\n")
            let cutLen = (nl.location == NSNotFound) ? storage.length : nl.location + 1
            storage.deleteCharacters(in: NSRange(location: 0, length: cutLen))
            lineCount = max(0, lineCount - 1)
        }
    }

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0

        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let coord = Coordinator(textView: tv)
        onReady(coord)
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = context.coordinator.textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
