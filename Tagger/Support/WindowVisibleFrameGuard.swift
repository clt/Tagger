import AppKit
import SwiftUI

/// Keeps restored and resized windows inside the current display's usable area.
/// This bridge supports macOS 14 without taking over SwiftUI's window delegate.
struct WindowVisibleFrameGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibleFrameView { VisibleFrameView() }
    func updateNSView(_ nsView: VisibleFrameView, context: Context) {}

    static func dismantleNSView(_ nsView: VisibleFrameView, coordinator: ()) {
        nsView.stopObserving()
    }
}

enum WindowFrameBounds {
    static func constrain(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.maxY - height, visibleFrame.minY), visibleFrame.maxY - height),
            width: width, height: height
        )
    }
}

@MainActor
final class VisibleFrameView: NSView {
    private var adjustmentPending = false
    private var lastAdjustment: [NSRect]?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        lastAdjustment = nil
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(scheduleAdjustment), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(scheduleAdjustment),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        scheduleAdjustment()
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scheduleAdjustment() {
        guard !adjustmentPending else { return }
        adjustmentPending = true
        // Let SwiftUI finish installing content constraints before repairing a restored frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            adjustmentPending = false
            guard let window, !window.inLiveResize, !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let frame = WindowFrameBounds.constrain(window.frame, to: screen.visibleFrame)
            guard frame != window.frame else {
                lastAdjustment = nil
                return
            }
            // A display can be smaller than the content minimum. Do not loop if
            // AppKit cannot honor the requested frame; retry when geometry changes.
            let geometry = [window.frame, screen.visibleFrame,
                            NSRect(origin: .zero, size: window.contentMinSize)]
            guard lastAdjustment != geometry else { return }
            lastAdjustment = geometry
            window.setFrame(frame, display: true)
        }
    }
}
