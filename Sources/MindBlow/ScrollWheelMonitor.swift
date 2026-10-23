import SwiftUI
import AppKit

/// Invisible view that captures scroll-wheel events over the canvas via a
/// local event monitor (SwiftUI has no scroll-wheel API on macOS).
struct ScrollWheelMonitor: NSViewRepresentable {
    /// (event, location in top-left coords, view size) → true when handled.
    var onScroll: (NSEvent, CGPoint, CGSize) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var onScroll: ((NSEvent, CGPoint, CGSize) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                let handled = self.onScroll?(event, local, self.bounds.size) ?? false
                return handled ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
