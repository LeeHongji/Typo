import AppKit

/// The box capture: every screen dims, the pointer becomes a crosshair, and the
/// box the user drags is shot when they let go. Esc, a right click, or a click
/// without dragging cancels.
@MainActor
final class RegionCaptureOverlay {
    /// Smaller than this on either side is a click, not a box.
    nonisolated static let minimumSide: CGFloat = 6

    private var panels: [NSPanel] = []
    private let finish: (CGRect?) -> Void
    private var done = false
    /// The app in front before the box; it gets the focus back after.
    private var previous: NSRunningApplication?

    init(finish: @escaping (CGRect?) -> Void) {
        self.finish = finish
    }

    func show() {
        for screen in NSScreen.screens {
            let panel = RegionPanel(screen: screen)
            let view = RegionCaptureView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenOrigin = screen.frame.origin
            view.showsHint = screen == NSScreen.main
            view.onFinish = { [weak self] rect in self?.complete(rect) }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Only the app in front may set the pointer, so Type4Me comes forward
        // for the moment of the box to show the crosshair, then hands back.
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own { previous = front }
        NSApp.activate(ignoringOtherApps: true)
        let underPointer = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        underPointer?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    func cancel() { complete(nil) }

    private func complete(_ rect: CGRect?) {
        guard !done else { return }
        done = true
        panels.forEach { $0.orderOut(nil) }
        panels = []
        NSCursor.arrow.set()
        previous?.activate()
        previous = nil
        finish(rect)
    }

    /// The box between two corners, in screen points.
    nonisolated static func box(from a: CGPoint, to b: CGPoint) -> CGRect? {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard rect.width >= minimumSide, rect.height >= minimumSide else { return nil }
        return rect.integral
    }
}

private final class RegionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionCaptureView: NSView {
    var screenOrigin: CGPoint = .zero
    var showsHint = false
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        let box = RegionCaptureOverlay.box(from: start, to: end)
            .map { $0.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y) }
        onFinish?(box)
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection).reversed) }
        NSColor.black.withAlphaComponent(0.28).setFill()
        dim.fill()

        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                      at: CGPoint(x: selection.maxX, y: selection.minY), alignRight: true, below: true)
        } else if showsHint {
            let hint = AttachmentCopy.regionHint
            drawLabel(hint, at: CGPoint(x: bounds.midX, y: bounds.maxY - 90), centred: true)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, alignRight: Bool = false, below: Bool = false, centred: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: centred ? 14 : 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pad = CGSize(width: centred ? 14 : 6, height: centred ? 7 : 3)
        var origin = point
        if centred { origin.x -= size.width / 2 + pad.width }
        if alignRight { origin.x -= size.width + pad.width * 2 }
        if below { origin.y -= size.height + pad.height * 2 + 4 }
        let box = CGRect(origin: origin, size: CGSize(width: size.width + pad.width * 2, height: size.height + pad.height * 2))
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }
}
