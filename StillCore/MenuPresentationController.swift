import AppKit
import SwiftUI

enum PresentationMode: Equatable {
    case attached
    case pinned
}

@MainActor
final class MenuPresentationState: ObservableObject {
    @Published private(set) var mode: PresentationMode = .attached
    @Published private(set) var isWindowVisible: Bool = false

    private var onModeChange: ((PresentationMode) -> Void)?

    func setPresentationMode(_ mode: PresentationMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        onModeChange?(mode)
    }

    fileprivate func bind(onModeChange: @escaping (PresentationMode) -> Void) {
        self.onModeChange = onModeChange
    }

    fileprivate func setWindowVisible(_ isVisible: Bool) {
        guard isWindowVisible != isVisible else { return }
        isWindowVisible = isVisible
    }
}

private let bootstrapWindowFrame = NSRect(x: 0, y: 0, width: 1, height: 1)

@MainActor
private func makeHostingContainer(rootView: AnyView) -> (containerView: NSView, hostingView: NSHostingView<AnyView>) {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.sizingOptions = []

    let containerView = NSView(frame: bootstrapWindowFrame)
    containerView.autoresizesSubviews = true
    hostingView.frame = containerView.bounds
    hostingView.autoresizingMask = [.width, .height]
    containerView.addSubview(hostingView)

    return (containerView, hostingView)
}

@MainActor
final class MenuPresentationController<Content: View>: NSObject, NSWindowDelegate {
    typealias ContentBuilder = (MenuPresentationState) -> Content

    private let statusItemStorage = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let presentationState = MenuPresentationState()
    private let hostingView: NSHostingView<AnyView>
    private let managedWindow: NSWindow

    var statusItem: NSStatusItem { statusItemStorage }
    var window: NSWindow { managedWindow }
    private var presentationMode: PresentationMode { presentationState.mode }

    init(
        @ViewBuilder content: @escaping ContentBuilder,
        configureStatusItem: ((NSStatusItem) -> Void)? = nil,
        configureWindow: ((NSWindow) -> Void)? = nil
    ) {
        let hosted = makeHostingContainer(rootView: AnyView(content(presentationState)))
        hostingView = hosted.hostingView

        managedWindow = NSWindow(
            contentRect: bootstrapWindowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        managedWindow.contentView = hosted.containerView
        managedWindow.isReleasedWhenClosed = false

        super.init()

        managedWindow.delegate = self
        configureStatusItem?(statusItemStorage)
        configureWindow?(managedWindow)
        configureStatusItemAction()

        presentationState.bind { [weak self] nextMode in
            self?.setPresentationMode(nextMode)
        }
        setPresentationMode(presentationMode)
    }

    func setPresentationMode(_ mode: PresentationMode) {
        switch mode {
        case .attached:
            // Window mode change should be on off-screen window
            managedWindow.orderOut(nil)
            hostingView.safeAreaRegions = []
            managedWindow.styleMask = [.titled, .fullSizeContentView, .closable, .resizable]
            managedWindow.titleVisibility = .hidden
            managedWindow.titlebarAppearsTransparent = true
            managedWindow.isMovableByWindowBackground = false
            managedWindow.level = .statusBar
            managedWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            managedWindow.standardWindowButton(.closeButton)?.isHidden = true
            managedWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            managedWindow.standardWindowButton(.zoomButton)?.isHidden = true

        case .pinned:
            hostingView.safeAreaRegions = .all
            managedWindow.styleMask = [.titled, .closable, .resizable]
            managedWindow.titleVisibility = .visible
            managedWindow.titlebarAppearsTransparent = false
            managedWindow.isMovableByWindowBackground = false
            managedWindow.level = .normal
            managedWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
            managedWindow.standardWindowButton(.closeButton)?.isHidden = false
            managedWindow.standardWindowButton(.miniaturizeButton)?.isHidden = false
            managedWindow.standardWindowButton(.zoomButton)?.isHidden = false
        }
        syncActivationPolicy()
    }

    private func showWindow() {
        if presentationMode == .attached {
            repositionAttachedWindow()
        }
        managedWindow.makeKeyAndOrderFront(nil)
        presentationState.setWindowVisible(true)
        NSApp.activate()
        syncActivationPolicy()
    }

    private func hideWindow() {
        managedWindow.orderOut(nil)
        presentationState.setWindowVisible(false)
        syncActivationPolicy()
    }

    private func syncActivationPolicy() {
        let desiredActivationPolicy: NSApplication.ActivationPolicy =
            presentationMode == .pinned && managedWindow.isVisible ? .regular : .accessory

        if NSApp.activationPolicy() != desiredActivationPolicy {
            NSApp.setActivationPolicy(desiredActivationPolicy)
        }
    }

    private func configureStatusItemAction() {
        guard let button = statusItemStorage.button else { return }
        button.target = self
        button.action = #selector(toggleFromStatusItem)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    private func repositionAttachedWindow() {
        guard let button = statusItemStorage.button, let buttonWindow = button.window else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let windowSize = managedWindow.frame.size

        var originX = buttonFrameOnScreen.midX - (windowSize.width / 2)
        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - windowSize.width - 8)

        let originY = max(visibleFrame.minY + 8, buttonFrameOnScreen.minY - windowSize.height - 8)
        managedWindow.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    @objc private func toggleFromStatusItem() {
        if presentationMode == .pinned, !managedWindow.isKeyWindow {
            showWindow()
        } else if managedWindow.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // Hide window on focus loss in attached mode
    func windowDidResignKey(_ notification: Notification) {
        if presentationMode == .attached {
            hideWindow()
        }
    }

    // Prevent closing window when user hit cmd+w or click close button in pinned mode
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if presentationMode == .pinned {
            presentationState.setPresentationMode(.attached)
        }
        hideWindow()
        return false
    }
}
