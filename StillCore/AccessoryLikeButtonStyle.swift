import AppKit
import SwiftUI

struct AccessoryLikeButtonStyle: ButtonStyle {
    @State private var isHovered = false

    var cornerRadius: CGFloat = 6
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 3
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        let rect = RoundedRectangle(cornerRadius: cornerRadius)

        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                rect.fill(background(isPressed: configuration.isPressed))
            }
            .contentShape(rect)
            .background {
                AppKitHoverProbeView(isHovered: $isHovered)
            }
            .onChange(of: isSelected) { _, selected in
                if !selected { isHovered = false }
            }
    }

    private func background(isPressed: Bool) -> some ShapeStyle {
        if isPressed {
            AnyShapeStyle(.quaternary)
        } else if isHovered || isSelected {
            AnyShapeStyle(.quinary)
        } else {
            AnyShapeStyle(.clear)
        }
    }
}

private struct AppKitHoverProbeView: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> HoverView {
        HoverView(isHovered: $isHovered)
    }

    func updateNSView(_ nsView: HoverView, context: Context) {
        nsView.isHovered = $isHovered
    }

    final class HoverView: NSView {
        var isHovered: Binding<Bool>

        init(isHovered: Binding<Bool>) {
            self.isHovered = isHovered
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered.wrappedValue = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovered.wrappedValue = false
        }
    }
}
