import AppKit
import QuartzCore
import SwiftUI

/// A borderless window that never takes a click, for effects drawn over other apps.
private final class EffectPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the capture surfaces say, in the current language.
enum AttachmentCopy {
    static var clickHint: String { L("点击窗口截图 · ⌘+点击照常操作", "Click a window to capture · ⌘-click to use it") }
    static var area: String { L("框选", "Area") }
    static var areaHelp: String { L("拖动框选屏幕上的一块区域截图", "Drag a box over the screen to capture it") }
    static var regionHint: String { L("拖动框选要截的区域 · Esc 取消", "Drag to capture an area · Esc to cancel") }
}

/// Short forms of a quote for chips, cards and the bar.
enum AttachmentPreview {
    static func short(_ quote: String, limit: Int = 14) -> String {
        let flat = quote.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// The moment of a capture: an outline flashes on what was taken, then a small
/// card of it flies in an arc: a quote into the words on the bar, a screenshot
/// to the tray above it.
@MainActor
enum AttachmentEffects {
    static let accent = NSColor(calibratedRed: 0.16, green: 0.47, blue: 1, alpha: 1)

    static func play(_ item: DictationAttachment, to target: CGPoint?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A screenshot flashed when the shutter fired.
        if case .quote = item.kind, item.source.width > 1, item.source.height > 1 { flash(item.source) }
        guard let target, !reduceMotion else { return }
        let start = item.source.width > 1
            ? CGPoint(x: item.source.midX, y: item.source.midY)
            : NSEvent.mouseLocation
        fly(card(for: item), from: start, to: target, duration: DictationAttachments.flightDuration)
    }

    // MARK: - Outline

    static func flash(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -5, dy: -4)
        let panel = EffectPanel(frame: frame.insetBy(dx: -3, dy: -3))
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        let outline = CAShapeLayer()
        let box = CGRect(origin: CGPoint(x: 3, y: 3), size: frame.size)
        outline.path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        outline.fillColor = accent.withAlphaComponent(0.08).cgColor
        outline.strokeColor = accent.cgColor
        outline.lineWidth = 2.5
        view.layer?.addSublayer(outline)
        panel.contentView = view
        panel.orderFrontRegardless()

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.55, 1]
        fade.duration = 0.6
        outline.opacity = 0
        outline.add(fade, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { panel.orderOut(nil) }
    }

    // MARK: - Card

    private static func card(for item: DictationAttachment) -> NSView {
        let content: AnyView
        switch item.kind {
        case .quote(let text):
            content = AnyView(AttachmentCard(icon: "text.quote", label: AttachmentChip.preview(of: text), thumbnail: nil))
        case .screenshot:
            content = AnyView(AttachmentCard(icon: "camera.viewfinder", label: nil, thumbnail: item.thumbnail))
        }
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        return host
    }

    private static func fly(_ card: NSView, from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        let size = card.frame.size
        let panel = EffectPanel(frame: CGRect(origin: .zero, size: size))
        let holder = NSView(frame: CGRect(origin: .zero, size: size))
        holder.wantsLayer = true
        holder.addSubview(card)
        panel.contentView = holder
        // Up and over: higher the farther it goes, so it reads as thrown.
        let lift = min(220, 60 + hypot(end.x - start.x, end.y - start.y) * 0.25)
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift)
        let began = CACurrentMediaTime()

        func place(_ p: Double) {
            let t = CGFloat(p)
            let u = 1 - t
            let point = CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
            // Shrinks into Typo's hands as it arrives.
            let scale = 1 - 0.6 * t * t
            panel.setFrameOrigin(CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
            let centre = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            holder.layer?.sublayerTransform = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0), CATransform3DMakeScale(scale, scale, 1)),
                centre
            )
            panel.alphaValue = p > 0.8 ? (1 - p) / 0.2 : 1
        }
        place(0)
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                let p = min(1, (CACurrentMediaTime() - began) / duration)
                // Quick out of the hand, easing into the catch.
                let eased = 1 - pow(1 - p, 2.2)
                place(eased)
                if p >= 1 {
                    timer.invalidate()
                    panel.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The flying card: a quote's first words, or a screenshot's thumbnail.
private struct AttachmentCard: View {
    let icon: String
    let label: String?
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            if let label {
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, thumbnail == nil ? 10 : 4)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color(nsColor: AttachmentEffects.accent), lineWidth: 1.5))
        .padding(4)
    }
}

// MARK: - Tray

/// The row of chips above the recording bar: everything brought in so far,
/// each with a × to drop it. Hangs off the bar's window, so it moves with it.
@MainActor
final class DictationAttachmentTray {
    private let bar: NSWindow
    private let panel: NSPanel
    private let host: NSHostingView<AttachmentTrayView>
    private var timer: Timer?
    private let attachments = DictationAttachments.shared

    init(bar: NSWindow) {
        self.bar = bar
        host = NSHostingView(rootView: AttachmentTrayView(attachments: DictationAttachments.shared))
        host.sizingOptions = []
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = bar.level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = host
        attachments.onCapture = { [weak self] item in
            guard let self else { return }
            self.refresh()
            AttachmentEffects.play(item, to: self.catchPoint(for: item))
        }
        observe()
    }

    /// Re-lays the tray whenever what it shows changes.
    private func observe() {
        withObservationTracking {
            _ = attachments.items
            _ = attachments.notice
            _ = attachments.isCollecting
            _ = attachments.hasArmedWindow
            _ = attachments.quotesShowInline
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
        refresh()
    }

    private var shows: Bool {
        bar.isVisible && (
            !attachments.trayItems.isEmpty || attachments.notice != nil
                || (attachments.isCollecting && attachments.hasArmedWindow)
        )
    }

    func refresh() {
        guard shows else {
            if panel.isVisible {
                bar.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            timer?.invalidate()
            timer = nil
            return
        }
        let size = host.fittingSize
        let frame = CGRect(
            x: bar.frame.midX - size.width / 2, y: bar.frame.maxY + 4,
            width: size.width, height: size.height
        ).integral
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            bar.addChildWindow(panel, ordered: .above)
        }
        if timer == nil {
            // The bar changes size as it shows and hides its parts; keep centred on it.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// A quote flies into the words on the bar; anything else to where its chip appears.
    private func catchPoint(for item: DictationAttachment) -> CGPoint? {
        guard bar.isVisible else { return nil }
        if case .quote = item.kind, attachments.quotesShowInline {
            return CGPoint(x: bar.frame.midX + 30, y: bar.frame.midY)
        }
        return panel.isVisible
            ? CGPoint(x: panel.frame.minX + 30, y: panel.frame.midY)
            : CGPoint(x: bar.frame.midX, y: bar.frame.maxY + 16)
    }
}

/// One chip: an icon or thumbnail, a short label, and a × to drop it.
struct AttachmentChip: View {
    let item: DictationAttachment
    let onRemove: () -> Void
    @AppStorage("tf_language") private var language = AppLanguage.current.rawValue

    static func preview(of quote: String) -> String {
        AttachmentPreview.short(quote)
    }

    var body: some View {
        let _ = language
        HStack(spacing: 5) {
            switch item.kind {
            case .quote(let text):
                Image(systemName: "text.quote").font(.system(size: 10, weight: .semibold))
                Text(Self.preview(of: text)).font(.system(size: 11, weight: .medium)).lineLimit(1)
            case .screenshot:
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(L("截图", "Screenshot")).font(.system(size: 11, weight: .medium))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("移除", "Remove"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch item.kind {
        case .quote(let text): return L("引用：", "Quote: ") + Self.preview(of: text)
        case .screenshot: return L("截图", "Screenshot")
        }
    }
}

struct AttachmentTrayView: View {
    let attachments: DictationAttachments
    @AppStorage("tf_language") private var language = AppLanguage.current.rawValue

    var body: some View {
        let _ = language
        HStack(spacing: 6) {
            ForEach(attachments.trayItems) { item in
                AttachmentChip(item: item) { attachments.remove(item.id) }
            }
            if let notice = attachments.notice {
                noticeChip(notice)
            }
            if attachments.isCollecting {
                regionButton
            }
        }
        .padding(4)
        .fixedSize()
    }

    /// Box capture, and while a window is ready, how to use the dot.
    private var regionButton: some View {
        HStack(spacing: 6) {
            if attachments.hasArmedWindow && attachments.trayItems.isEmpty {
                Text(AttachmentCopy.clickHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button { attachments.captureRegion() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 10, weight: .semibold))
                    Text(AttachmentCopy.area).font(.system(size: 11, weight: .semibold))
                    Text("⌥S").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(AttachmentCopy.areaHelp)
            .accessibilityLabel(L("框选截图", "Capture an area"))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private func noticeChip(_ notice: DictationAttachments.Notice) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            switch notice {
            case .needsScreenRecording:
                Text(L("截图需要屏幕录制权限", "Screenshots need Screen Recording access"))
                    .font(.system(size: 11, weight: .medium))
                Button(L("打开设置", "Open Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                    attachments.dismissNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: AttachmentEffects.accent))
            case .screenshotFailed:
                Text(L("这个窗口截不了", "Couldn't capture that window")).font(.system(size: 11, weight: .medium))
            }
            Button { attachments.dismissNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("关闭", "Dismiss"))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Pointer dot and window outline

/// The dot beside the pointer while a click would shoot the window under it.
/// macOS lets an app in the background change no other app's pointer, so the
/// dot is a tiny window that follows it.
@MainActor
final class PointerDot {
    static let size: CGFloat = 14
    /// Below and right of the arrow's tip, clear of the arrow itself.
    static let offset = CGPoint(x: 11, y: -20)

    private var panel: EffectPanel?
    private var dotLayer: CALayer?

    func show(at pointer: CGPoint) {
        let panel = self.panel ?? make()
        panel.setFrameOrigin(CGPoint(x: pointer.x + Self.offset.x, y: pointer.y + Self.offset.y))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The shutter fired.
    func pulse() {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 0.55, 1.25, 1]
        pulse.keyTimes = [0, 0.25, 0.6, 1]
        pulse.duration = 0.3
        dotLayer?.add(pulse, forKey: "pulse")
    }

    private func make() -> EffectPanel {
        let panel = EffectPanel(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        panel.level = .screenSaver
        let view = NSView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let dot = CALayer()
        dot.frame = view.bounds.insetBy(dx: 1.5, dy: 1.5)
        dot.cornerRadius = dot.frame.width / 2
        dot.backgroundColor = NSColor.black.cgColor
        dot.borderColor = NSColor.white.cgColor
        dot.borderWidth = 2
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 1.5
        dot.shadowOffset = CGSize(width: 0, height: -0.5)
        view.layer?.addSublayer(dot)
        panel.contentView = view
        self.panel = panel
        dotLayer = dot
        return panel
    }
}

/// A soft outline around the window a click would shoot.
@MainActor
final class WindowOutline {
    private var panel: EffectPanel?
    private var shape: CAShapeLayer?
    private var shown: CGRect?

    func show(_ frame: CGRect) {
        let panel = self.panel ?? make()
        if shown != frame {
            shown = frame
            let outer = frame.insetBy(dx: -3, dy: -3)
            panel.setFrame(outer, display: false)
            shape?.frame = CGRect(origin: .zero, size: outer.size)
            shape?.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: outer.size).insetBy(dx: 1.5, dy: 1.5),
                cornerWidth: 12, cornerHeight: 12, transform: nil
            )
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        shown = nil
    }

    private func make() -> EffectPanel {
        let panel = EffectPanel(frame: .zero)
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.autoresizesSubviews = true
        let shape = CAShapeLayer()
        shape.fillColor = AttachmentEffects.accent.withAlphaComponent(0.05).cgColor
        shape.strokeColor = AttachmentEffects.accent.withAlphaComponent(0.75).cgColor
        shape.lineWidth = 2
        view.layer?.addSublayer(shape)
        panel.contentView = view
        self.panel = panel
        self.shape = shape
        return panel
    }
}
