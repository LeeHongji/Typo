import AppKit
import ApplicationServices
import Observation
import QuartzCore
import ScreenCaptureKit

/// Something brought into a dictation while the user talks: text selected
/// anywhere on screen (a quote), or a window clicked (its screenshot). It goes
/// out with the words when the user lets go.
struct DictationAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case quote(String)
        case screenshot(URL)
    }

    let id = UUID()
    let kind: Kind
    /// Where on screen it came from (AppKit coordinates), for the capture effects.
    let source: CGRect
    /// When its card reaches Typo; until then it is still in the air.
    let arrivesAt: TimeInterval
    var thumbnail: NSImage?

    static func == (a: DictationAttachment, b: DictationAttachment) -> Bool { a.id == b.id }
}

/// What delivery pastes, decided once the words are final.
struct DictationDelivery: Equatable, Sendable {
    var quotes: [String] = []
    var screenshots: [URL] = []

    var isEmpty: Bool { quotes.isEmpty && screenshots.isEmpty }
    var count: Int { quotes.count + screenshots.count }

    /// Quotes go before the words, each line marked `> `, a blank line after
    /// each quote, so the words read as a reply to them.
    static func text(speech: String, quotes: [String]) -> String {
        guard !quotes.isEmpty else { return speech }
        let blocks = quotes.map { quote in
            quote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")
        }
        return (blocks + [speech]).joined(separator: "\n\n")
    }

    /// Terminals take no pasted images; they get the file's path instead.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "co.zeit.hyper", "com.github.wez.wezterm", "com.raphaelamorim.rio", "dev.zed.Zed-Terminal",
    ]

    static func pastesPaths(into bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(terminalBundles.contains) ?? false
    }

    /// A path a shell reads as one word.
    static func shellQuoted(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return safe ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The attachments of the dictation under way, and what the user is told
/// about them. Collects only while recording.
@MainActor
@Observable
final class DictationAttachments {
    static let shared = DictationAttachments()

    enum Notice: Equatable {
        case needsScreenRecording
        case screenshotFailed
    }

    /// The card's flight from where it was captured to Typo.
    static let flightDuration: TimeInterval = 0.5
    static let maxQuoteCharacters = 4000
    static let maxScreenshotSide: CGFloat = 1600

    private(set) var items: [DictationAttachment] = []
    private(set) var notice: Notice?
    private(set) var isCollecting = false
    /// Delivered with the words; Typo still carries them while it leaps.
    private(set) var delivering = 0

    /// Called with each capture so the screen effects can play.
    @ObservationIgnored var onCapture: ((DictationAttachment) -> Void)?
    /// Where Typo stands beside the caret, so a card can fly to it (screen points).
    @ObservationIgnored var caretCatchPoint: CGPoint?
    /// Where the next chip goes above the bar, when Typo is on the bar.
    @ObservationIgnored var trayCatchPoint: CGPoint?
    var catchPoint: CGPoint? { caretCatchPoint ?? trayCatchPoint }

    @ObservationIgnored private var collector: DictationPointerCollector?
    @ObservationIgnored private var sessionID = UUID()

    /// How many cards Typo has caught by `now`, including those on their way into the text.
    func carried(at now: TimeInterval) -> Int {
        items.filter { $0.arrivesAt <= now }.count + delivering
    }

    // MARK: - Session

    func begin(targetPID: pid_t?, targetWindowID: CGWindowID?) {
        guard !isCollecting else { return }
        discardFiles(of: items)
        items = []
        notice = nil
        delivering = 0
        sessionID = UUID()
        isCollecting = true
        Self.removeStaleFiles()
        let collector = DictationPointerCollector(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            targetWindowID: targetWindowID
        ) { [weak self] capture in self?.take(capture) }
        DebugFileLogger.log("attachments: collecting target=\(targetPID.map(String.init) ?? "-") window=\(targetWindowID.map(String.init) ?? "-")")
        collector.start()
        self.collector = collector
    }

    /// The user stopped talking: no more captures, keep what was caught.
    func stopCollecting() {
        isCollecting = false
        collector?.stop()
        collector = nil
    }

    /// Hands everything over to delivery.
    func takeForDelivery() -> DictationDelivery {
        stopCollecting()
        var delivery = DictationDelivery()
        for item in items {
            switch item.kind {
            case .quote(let text): delivery.quotes.append(text)
            case .screenshot(let url): delivery.screenshots.append(url)
            }
        }
        delivering = items.count
        items = []
        notice = nil
        return delivery
    }

    /// The bar is gone: drop what was never delivered (a cancel).
    func end() {
        stopCollecting()
        discardFiles(of: items)
        items = []
        notice = nil
        let session = sessionID
        // Typo may still be leaping with the delivered cards; let it land.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessionID == session, !self.isCollecting else { return }
            self.delivering = 0
        }
    }

    func remove(_ id: DictationAttachment.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        discardFiles(of: [items[index]])
        items.remove(at: index)
    }

    func dismissNotice() { notice = nil }

    // MARK: - Captures

    private func take(_ capture: DictationPointerCollector.Capture) {
        guard isCollecting else { return }
        let now = CACurrentMediaTime()
        switch capture {
        case .quote(let text, let rect):
            let quote = Self.trimmedQuote(text)
            guard !quote.isEmpty, !items.contains(where: { $0.kind == .quote(quote) }) else { return }
            add(DictationAttachment(kind: .quote(quote), source: rect, arrivesAt: now + Self.flightDuration))
        case .window(let id, let frame):
            let session = sessionID
            Task { [weak self] in
                let result = await Self.screenshot(windowID: id)
                guard let self, self.sessionID == session, self.isCollecting else { return }
                switch result {
                case .success(let shot):
                    var item = DictationAttachment(
                        kind: .screenshot(shot.url), source: frame,
                        arrivesAt: CACurrentMediaTime() + Self.flightDuration
                    )
                    item.thumbnail = shot.thumbnail
                    self.add(item)
                case .failure(let failure):
                    self.notice = failure == .permission ? .needsScreenRecording : .screenshotFailed
                }
            }
        }
    }

    private func add(_ item: DictationAttachment) {
        items.append(item)
        DebugFileLogger.log("attachments: caught \(item.kind.logName) count=\(items.count)")
        onCapture?(item)
    }

    static func trimmedQuote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxQuoteCharacters else { return trimmed }
        return String(trimmed.prefix(maxQuoteCharacters)) + "…"
    }

    // MARK: - Screenshots

    enum ShotFailure: Error { case permission, capture }
    struct Shot { let url: URL; let thumbnail: NSImage }

    private static var askedForScreenRecording = false

    /// Captures one window with ScreenCaptureKit. Screen Recording access is
    /// asked for the first time a screenshot is needed, not before.
    static func screenshot(windowID: CGWindowID) async -> Result<Shot, ShotFailure> {
        if !CGPreflightScreenCaptureAccess() {
            if !askedForScreenRecording {
                askedForScreenRecording = true
                CGRequestScreenCaptureAccess()
            }
            return .failure(.permission)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return .failure(.capture)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let size = window.frame.size
            let fit = min(1, maxScreenshotSide / max(size.width * scale, size.height * scale, 1))
            config.width = max(1, Int(size.width * scale * fit))
            config.height = max(1, Int(size.height * scale * fit))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let url = try write(image)
            return .success(Shot(url: url, thumbnail: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))))
        } catch {
            DebugFileLogger.log("attachments: screenshot failed \(error.localizedDescription)")
            return .failure(.capture)
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Type4Me/attachments", isDirectory: true)
    }

    private static func write(_ image: CGImage) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = directory.appendingPathComponent("screenshot-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ShotFailure.capture
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotFailure.capture }
        return url
    }

    /// Delivered screenshots stay a day, so a terminal tool can still read a pasted path.
    private static func removeStaleFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dayAgo = Date().addingTimeInterval(-86_400)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < dayAgo { try? fm.removeItem(at: file) }
        }
    }

    private func discardFiles(of items: [DictationAttachment]) {
        for item in items {
            if case .screenshot(let url) = item.kind { try? FileManager.default.removeItem(at: url) }
        }
    }
}

private extension DictationAttachment.Kind {
    var logName: String {
        switch self {
        case .quote(let text): return "quote chars=\(text.count)"
        case .screenshot: return "screenshot"
        }
    }
}

/// Watches the mouse in other apps while the user talks: a drag (or a double
/// or triple click) selects text to quote; a single click on another window
/// asks for its screenshot. Type4Me's own windows never reach a global
/// monitor, and a click on the window being dictated into does not count.
@MainActor
final class DictationPointerCollector {
    enum Capture {
        case quote(String, CGRect)
        case window(CGWindowID, CGRect)
    }

    /// What a finished gesture means, before anything is read.
    enum Gesture: Equatable {
        case selection
        case windowClick(CGWindowID)
        case none
    }

    /// Farther than this between press and release is a drag.
    nonisolated static let dragDistance: CGFloat = 4

    /// Pure classification of one press-and-release.
    nonisolated static func classify(
        down: CGPoint, up: CGPoint, clickCount: Int,
        window: (id: CGWindowID, owner: pid_t)?, ownPID: pid_t, targetWindowID: CGWindowID?
    ) -> Gesture {
        guard let window, window.owner != ownPID else { return .none }
        if hypot(up.x - down.x, up.y - down.y) > dragDistance || clickCount >= 2 {
            return .selection
        }
        guard clickCount == 1, window.id != targetWindowID else { return .none }
        return .windowClick(window.id)
    }

    private let ownPID: pid_t
    private let targetWindowID: CGWindowID?
    private let deliver: (Capture) -> Void
    private var monitors: [Any] = []
    private var downPoint: CGPoint?
    private var downWindow: WindowHit?

    struct WindowHit {
        let id: CGWindowID
        let owner: pid_t
        let frame: CGRect
    }

    init(ownPID: pid_t, targetWindowID: CGWindowID?, deliver: @escaping (Capture) -> Void) {
        self.ownPID = ownPID
        self.targetWindowID = targetWindowID
        self.deliver = deliver
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            let clicks = event.clickCount
            MainActor.assumeIsolated { self?.mouseUp(clickCount: clicks) }
        }) { monitors.append(up) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func mouseDown() {
        downPoint = NSEvent.mouseLocation
        downWindow = Self.window(at: NSEvent.mouseLocation, excluding: ownPID)
    }

    private func mouseUp(clickCount: Int) {
        guard let down = downPoint else { return }
        let up = NSEvent.mouseLocation
        let hit = downWindow
        downPoint = nil
        switch Self.classify(
            down: down, up: up, clickCount: clickCount,
            window: hit.map { ($0.id, $0.owner) }, ownPID: ownPID, targetWindowID: targetWindowID
        ) {
        case .none:
            return
        case .windowClick(let id):
            deliver(.window(id, hit?.frame ?? .zero))
        case .selection:
            guard let owner = hit?.owner else { return }
            let dragBox = CGRect(
                x: min(down.x, up.x), y: min(down.y, up.y) - 8,
                width: max(abs(up.x - down.x), 16), height: abs(up.y - down.y) + 20
            )
            Task { [weak self] in
                // Let the app finish updating its selection.
                try? await Task.sleep(for: .milliseconds(140))
                guard let self else { return }
                let read = await Self.selection(in: owner)
                // Selecting inside the box being dictated into is editing it,
                // not quoting: the paste would replace that selection.
                if hit?.id == self.targetWindowID, let role = read?.role, DictationDestination.textRoles.contains(role) {
                    return
                }
                var text = read?.text ?? ""
                if text.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == owner {
                    // Some apps expose no selection to Accessibility; copy it, then put the clipboard back.
                    text = await PromptContext.readSelectedTextByTemporaryCopy(timeoutMs: 250)
                }
                guard !text.isEmpty else { return }
                self.deliver(.quote(text, read?.bounds ?? dragBox))
            }
        }
    }

    // MARK: - Window server and AX

    /// The topmost ordinary window under an AppKit point, other than our own.
    static func window(at point: CGPoint, excluding ownPID: pid_t) -> WindowHit? {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryMaxY - point.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint)
            else { continue }
            let frame = CGRect(x: bounds.minX, y: primaryMaxY - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowHit(id: CGWindowID(number), owner: owner, frame: frame)
        }
        return nil
    }

    private static let queue = DispatchQueue(label: "com.type4me.attachments-ax", qos: .userInitiated)

    /// The selected text of an app and, when it says, where it is on screen.
    static func selection(in pid: pid_t) async -> (text: String, bounds: CGRect?, role: String?)? {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return await withCheckedContinuation { continuation in
            queue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                guard let element = DictationDestination.copyElement(app, kAXFocusedUIElementAttribute) else {
                    continuation.resume(returning: nil)
                    return
                }
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
                var text = (value as? String) ?? ""
                // A web page's selection is in text markers, not a text range.
                if text.isEmpty {
                    var marker: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker {
                        var string: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, marker, &string) == .success {
                            text = (string as? String) ?? ""
                        }
                    }
                }
                let bounds = selectionBounds(element).map {
                    CGRect(x: $0.minX, y: primaryMaxY - $0.maxY, width: $0.width, height: $0.height)
                }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                continuation.resume(returning: (text, bounds, role as? String))
            }
        }
    }

    /// Selection bounds in AX coordinates: text markers (web), then ranges.
    private static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        func rect(_ value: CFTypeRef?) -> CGRect? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var r = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &r), r.width > 1, r.height > 1 else { return nil }
            return r
        }
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, marker, &out) == .success,
               let r = rect(out) { return r }
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &out) == .success,
               let r = rect(out) { return r }
        }
        return nil
    }
}
