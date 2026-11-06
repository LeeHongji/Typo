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
    /// For a quote: the words the user had said when the selecting began, and
    /// how many seconds into the recording that was, so it goes in right there.
    var spokenPrefix = ""
    var spokenAt: TimeInterval = 0

    static func == (a: DictationAttachment, b: DictationAttachment) -> Bool { a.id == b.id }
}

/// A quote and where in the talk it was brought in.
struct PlacedQuote: Equatable, Sendable {
    let text: String
    /// The words said before it.
    var spokenPrefix: String = ""
    /// How far into the recording it was selected, 0…1, for when nothing was heard yet.
    var spokenFraction: Double? = nil
    /// Seconds into the recording when the selecting began.
    var audioTime: TimeInterval? = nil
}

/// Markers that carry quotes' places through a mode that rewrites the words:
/// ⟦Q1⟧ goes into the text the model sees, and where it comes back is where
/// the quote goes. A marker that comes back missing or twice gives no place,
/// and the quote is placed by matching the words instead.
enum QuoteMarkers {
    static func token(_ index: Int) -> String { "⟦Q\(index + 1)⟧" }

    static let instruction = """


    The text contains markers like ⟦Q1⟧ where quoted material will be inserted. \
    Keep every marker exactly once and unchanged, at the matching place in your output. Do not add markers.
    """

    /// The words with each quote's marker where it goes.
    static func mark(_ text: String, quotes: [PlacedQuote]) -> String {
        var places: [(index: Int, offset: Int)] = []
        for (index, quote) in quotes.enumerated() {
            let at = DictationDelivery.insertionIndex(for: quote, in: text)
            places.append((index, text.distance(from: text.startIndex, to: at)))
        }
        // From the end, so earlier offsets stay valid; the same place keeps the order.
        places.sort { a, b in a.offset == b.offset ? a.index > b.index : a.offset > b.offset }
        var marked = text
        for place in places {
            marked.insert(contentsOf: token(place.index), at: marked.index(marked.startIndex, offsetBy: place.offset))
        }
        return marked
    }

    /// The model's words without markers, and for each quote the words before
    /// its marker, or nil when any marker did not come back exactly once.
    static func extract(_ text: String, count: Int) -> (text: String, prefixes: [String]?) {
        let stripped = strip(text)
        guard count > 0 else { return (stripped, nil) }
        var prefixes: [String] = []
        for index in 0..<count {
            let token = token(index)
            let ranges = text.ranges(of: token)
            guard ranges.count == 1, let range = ranges.first else { return (stripped, nil) }
            prefixes.append(strip(String(text[..<range.lowerBound])))
        }
        return (stripped, prefixes)
    }

    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "⟦Q[0-9]+⟧", with: "", options: .regularExpression)
    }
}

/// What delivery pastes, decided once the words are final.
struct DictationDelivery: Equatable, Sendable {
    var quotes: [PlacedQuote] = []
    var screenshots: [URL] = []

    var isEmpty: Bool { quotes.isEmpty && screenshots.isEmpty }
    var count: Int { quotes.count + screenshots.count }

    /// Short single-line quotes sit inside the sentence.
    static let inlineQuoteLimit = 80

    static func isInline(_ quote: String) -> Bool {
        !quote.contains("\n") && quote.count <= inlineQuoteLimit
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJK($0) }
    }

    /// Each quote goes where the user was talking when they selected it: a short
    /// one inside the sentence in 「」 (or “” for non-CJK text), a long or
    /// multi-line one as its own `> ` block on blank lines.
    static func text(speech: String, quotes: [PlacedQuote]) -> String {
        var out = ""
        var pendingBreak = false
        for piece in pieces(speech: speech, quotes: quotes) {
            switch piece {
            case .speech(let words):
                var words = words
                if pendingBreak {
                    words = String(words.drop(while: \.isWhitespace))
                    guard !words.isEmpty else { continue }
                    out += "\n\n"
                    pendingBreak = false
                }
                out += words
            case .quote(let quote, let next):
                if isInline(quote) {
                    if pendingBreak { out += "\n\n"; pendingBreak = false }
                    let marked = containsCJK(quote) ? "「\(quote)」" : "“\(quote)”"
                    if let last = out.last, needsSpace(between: last, and: marked.first!) { out += " " }
                    out += marked
                    if let next, needsSpace(between: marked.last!, and: next) { out += " " }
                } else {
                    while out.last?.isWhitespace == true { out.removeLast() }
                    if !out.isEmpty { out += "\n\n" }
                    out += quote.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> " + $0 }
                        .joined(separator: "\n")
                    pendingBreak = true
                }
            }
        }
        return out
    }

    /// Each quote and how many characters into the words it goes, in order.
    static func placements(speech: String, quotes: [PlacedQuote]) -> [(text: String, offset: Int)] {
        quotes
            .map { ($0.text, speech.distance(from: speech.startIndex, to: insertionIndex(for: $0, in: speech))) }
            .sorted { $0.1 < $1.1 }
            .map { (text: $0.0, offset: $0.1) }
    }

    enum Piece: Equatable {
        case speech(String)
        /// A quote, and the first character of the words after it.
        case quote(String, next: Character?)
    }

    /// The words cut where each quote goes, in order.
    static func pieces(speech: String, quotes: [PlacedQuote]) -> [Piece] {
        struct Placed { let order: Int; let quote: PlacedQuote; let at: String.Index }
        var placed: [Placed] = []
        for (order, quote) in quotes.enumerated() {
            placed.append(Placed(order: order, quote: quote, at: insertionIndex(for: quote, in: speech)))
        }
        placed.sort { a, b in a.at == b.at ? a.order < b.order : a.at < b.at }
        var pieces: [Piece] = []
        var cursor = speech.startIndex
        for item in placed {
            if cursor < item.at { pieces.append(.speech(String(speech[cursor..<item.at]))) }
            cursor = max(cursor, item.at)
            pieces.append(.quote(item.quote.text, next: cursor < speech.endIndex ? speech[cursor] : nil))
        }
        if cursor < speech.endIndex { pieces.append(.speech(String(speech[cursor...]))) }
        return pieces
    }

    // MARK: - Finding the place

    /// Where in the final words a quote goes. The words heard when it was
    /// selected are found again in the final text (which may differ: the
    /// recognizer revises, punctuation is added, a mode may rewrite); failing
    /// that, it goes as far in as it was in time, at a word boundary.
    static func insertionIndex(for quote: PlacedQuote, in text: String) -> String.Index {
        let target = normalized(text)
        let prefix = normalized(quote.spokenPrefix).map(\.char)
        guard !target.isEmpty else { return text.endIndex }

        var end: Int?
        var fromTime = false
        if !prefix.isEmpty {
            let expected = min(prefix.count, target.count)
            let chars = target.map(\.char)
            for length in [12, 8, 5, 3, 2, 1] where length <= prefix.count {
                let tail = Array(prefix.suffix(length))
                var best: Int?
                var i = 0
                while i + length <= chars.count {
                    if Array(chars[i..<(i + length)]) == tail {
                        let candidate = i + length
                        if best.map({ abs(candidate - expected) < abs($0 - expected) }) ?? true { best = candidate }
                    }
                    i += 1
                }
                // A match far from where the words were is a coincidence.
                if let best, abs(best - expected) <= max(6, expected / 2) {
                    end = best
                    break
                }
            }
            if end == nil { end = expected }
        } else if let fraction = quote.spokenFraction, fraction > 0 {
            end = Int((Double(target.count) * min(1, fraction)).rounded())
            fromTime = true
        } else {
            return text.startIndex
        }

        guard let end, end > 0 else { return text.startIndex }
        guard end < target.count else { return text.endIndex }
        var index = text.index(after: target[end - 1].index)
        // Not inside a word of a spaced language.
        while index < text.endIndex, isWordLetter(text[index]), isWordLetter(text[text.index(before: index)]) {
            index = text.index(after: index)
        }
        // The sentence's own punctuation stays with it: when the user had said
        // it, when the quote is a block of its own, or when only time placed it.
        let saidPunctuation = quote.spokenPrefix.last(where: { !$0.isWhitespace }).map { !$0.isLetter && !$0.isNumber } ?? false
        if saidPunctuation || fromTime || !isInline(quote.text) {
            while index < text.endIndex, isClosingPunctuation(text[index]) { index = text.index(after: index) }
        }
        return index
    }

    private static func normalized(_ text: String) -> [(char: Character, index: String.Index)] {
        var out: [(Character, String.Index)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber { out.append((c.lowercased().first ?? c, i)) }
            i = text.index(after: i)
        }
        return out
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isCJKChar(_ c: Character) -> Bool {
        c.unicodeScalars.first.map(isCJK) ?? false
    }

    /// A letter of a language written with spaces between words.
    private static func isWordLetter(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && !isCJKChar(c)
    }

    private static func isClosingPunctuation(_ c: Character) -> Bool {
        "，。！？、；：,.!?;:)）」』”’".contains(c)
    }

    /// Words of a spaced language, or Latin punctuation, keep a space next to a quote.
    static func needsSpace(between a: Character, and b: Character) -> Bool {
        if a.isWhitespace || b.isWhitespace { return false }
        if isCJKChar(a) || isCJKChar(b) || "，。！？、；：「」".contains(a) || "，。！？、；：「」".contains(b) { return false }
        if ",.!?;:".contains(b) { return false }
        return true
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
        /// The live stream broke; recording carries on.
        case connectionLost(String)
        /// ⌥S was pressed on the window being dictated into.
        case switchWindowFirst
    }

    /// The card's flight from where it was captured to the bar.
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

    /// The user is in another window, where ⌥S would shoot; the tray shows the shortcuts.
    private(set) var isAwayFromTarget = false
    /// The bar shows the words as they come, so quotes appear inside them;
    /// otherwise they are chips in the tray.
    var quotesShowInline = true
    /// Recognition lags the voice: without word timing, the words a quote
    /// follows are the ones shown this long after the selecting began.
    static let recognitionLag: TimeInterval = 0.7
    /// The live words as they came in, with when, to place quotes by time.
    @ObservationIgnored private var heard: [(at: TimeInterval, text: String)] = []
    @ObservationIgnored private var heardTimedWords: [TimedWord] = []

    @ObservationIgnored private var collector: DictationPointerCollector?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var stoppedAt: TimeInterval?

    /// The items shown as chips: screenshots, and quotes when not shown inline.
    var trayItems: [DictationAttachment] {
        items.filter { item in
            if case .quote = item.kind { return !quotesShowInline }
            return true
        }
    }

    /// Each live transcript update: remembered, and quotes re-placed as the
    /// words they follow firm up.
    func recordTranscript(_ text: String, timedWords: [TimedWord]) {
        guard isCollecting else { return }
        let now = CACurrentMediaTime()
        heard.append((now, text))
        if heard.count > 600 { heard.removeFirst(heard.count - 600) }
        heardTimedWords = timedWords
        for index in items.indices {
            guard case .quote = items[index].kind else { continue }
            let prefix = Self.spokenPrefix(
                selectionStart: startedAt + items[index].spokenAt, recordingStart: startedAt,
                timedWords: heardTimedWords, heard: heard
            )
            if prefix != items[index].spokenPrefix { items[index].spokenPrefix = prefix }
        }
    }

    /// Pure: the words said before a selection began. By the recognizer's word
    /// times when it gives them; otherwise the words shown `recognitionLag`
    /// after it began, since that is how long the words take to appear.
    nonisolated static func spokenPrefix(
        selectionStart: TimeInterval,
        recordingStart: TimeInterval,
        timedWords: [TimedWord],
        heard: [(at: TimeInterval, text: String)]
    ) -> String {
        if let byTime = TimedWord.prefix(timedWords, through: selectionStart - recordingStart) {
            return byTime
        }
        let shownBy = selectionStart + recognitionLag
        return heard.last { $0.at <= shownBy }?.text ?? ""
    }

    /// Quotes not yet delivered, placed as they stand, for a rewriting mode to carry.
    func pendingQuotes() -> [PlacedQuote] {
        items.compactMap { item in
            guard case .quote(let text) = item.kind else { return nil }
            return PlacedQuote(text: text, spokenPrefix: item.spokenPrefix, audioTime: item.spokenAt)
        }
    }

    /// Quotes in the words shown on the bar, placed where they were taken.
    var inlineQuotes: [PlacedQuote] {
        items.compactMap { item in
            guard case .quote(let text) = item.kind else { return nil }
            return PlacedQuote(text: AttachmentPreview.short(text), spokenPrefix: item.spokenPrefix)
        }
    }

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
        startedAt = CACurrentMediaTime()
        stoppedAt = nil
        heard = []
        heardTimedWords = []
        Self.removeStaleFiles()
        let collector = DictationPointerCollector(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            deliver: { [weak self] capture in self?.take(capture) },
            awayChanged: { [weak self] away in
                guard let self else { return }
                self.isAwayFromTarget = away
                // The hint to switch windows has done its job.
                if away, self.notice == .switchWindowFirst { self.notice = nil }
            }
        )
        DebugFileLogger.log("attachments: collecting target=\(targetPID.map(String.init) ?? "-") window=\(targetWindowID.map(String.init) ?? "-")")
        collector.start()
        self.collector = collector
    }

    /// The user stopped talking: no more captures, keep what was caught.
    func stopCollecting() {
        if isCollecting { stoppedAt = CACurrentMediaTime() }
        isCollecting = false
        isAwayFromTarget = false
        collector?.stop()
        collector = nil
    }

    /// Starts drawing a box to shoot (⌥S or the tray's button).
    func captureRegion() {
        guard isCollecting else { return }
        collector?.captureRegion()
    }

    /// Hands everything over to delivery.
    func takeForDelivery() -> DictationDelivery {
        stopCollecting()
        var delivery = DictationDelivery()
        let duration = max(0.001, (stoppedAt ?? CACurrentMediaTime()) - startedAt)
        for item in items {
            switch item.kind {
            case .quote(let text):
                delivery.quotes.append(PlacedQuote(
                    text: text, spokenPrefix: item.spokenPrefix, spokenFraction: item.spokenAt / duration,
                    audioTime: item.spokenAt
                ))
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

    func showNotice(_ notice: Notice) { self.notice = notice }

    // MARK: - Captures

    private func take(_ capture: DictationPointerCollector.Capture) {
        guard isCollecting else { return }
        let now = CACurrentMediaTime()
        switch capture {
        case .quote(let text, let rect, let selectionStart):
            let quote = Self.trimmedQuote(text)
            guard !quote.isEmpty, !items.contains(where: { $0.kind == .quote(quote) }) else { return }
            var item = DictationAttachment(kind: .quote(quote), source: rect, arrivesAt: now + Self.flightDuration)
            let start = min(max(selectionStart, startedAt), now)
            item.spokenAt = start - startedAt
            item.spokenPrefix = Self.spokenPrefix(
                selectionStart: start, recordingStart: startedAt, timedWords: heardTimedWords, heard: heard
            )
            add(item)
            // Without word timing, the words it follows are still on their way.
            let settle = start + Self.recognitionLag - now
            if heardTimedWords.isEmpty, settle > 0 {
                let id = item.id
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(settle * 1000) + 20))
                    self?.resettle(id)
                }
            }
        case .window(let id, let frame):
            shoot(frame: frame) { await Self.screenshot(windowID: id) }
        case .region(let rect):
            shoot(frame: rect) { await Self.screenshot(region: rect) }
        }
    }

    private func resettle(_ id: DictationAttachment.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].spokenPrefix = Self.spokenPrefix(
            selectionStart: startedAt + items[index].spokenAt, recordingStart: startedAt,
            timedWords: heardTimedWords, heard: heard
        )
    }

    private func shoot(frame: CGRect, _ capture: @escaping @MainActor () async -> Result<Shot, ShotFailure>) {
            let session = sessionID
            Task { [weak self] in
                let result = await capture()
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
    private static func hasScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !askedForScreenRecording {
            askedForScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    /// Captures an area of one display (AppKit coordinates), without Type4Me's own windows.
    static func screenshot(region: CGRect) async -> Result<Shot, ShotFailure> {
        guard hasScreenRecording() else { return .failure(.permission) }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return .failure(.capture) }
        let area = region.intersection(screen.frame)
        guard area.width >= 2, area.height >= 2 else { return .failure(.capture) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                return .failure(.capture)
            }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Display points, measured from the display's top left.
            config.sourceRect = CGRect(
                x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY,
                width: area.width, height: area.height
            )
            let scale = CGFloat(filter.pointPixelScale)
            let fit = min(1, maxScreenshotSide / max(area.width * scale, area.height * scale, 1))
            config.width = max(1, Int(area.width * scale * fit))
            config.height = max(1, Int(area.height * scale * fit))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let url = try write(image)
            return .success(Shot(url: url, thumbnail: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))))
        } catch {
            DebugFileLogger.log("attachments: region screenshot failed \(error.localizedDescription)")
            return .failure(.capture)
        }
    }

    static func screenshot(windowID: CGWindowID) async -> Result<Shot, ShotFailure> {
        guard hasScreenRecording() else { return .failure(.permission) }
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

/// Watches the user's hands while they talk. Selecting text anywhere (a drag,
/// a double or triple click) quotes it; ⌥S shoots the window in front, ⌥⇧S
/// draws a box to shoot. Clicks are only watched, never taken, so nothing is
/// shot by accident. Type4Me's own windows never reach a global monitor.
@MainActor
final class DictationPointerCollector {
    enum Capture {
        /// The selected text, where it is on screen, and when the selecting began.
        case quote(String, CGRect, startedAt: TimeInterval)
        case window(CGWindowID, CGRect)
        case region(CGRect)
    }

    /// What a finished press means for quoting.
    enum Gesture: Equatable {
        case selection
        case none
    }

    /// Farther than this between press and release is a drag.
    nonisolated static let dragDistance: CGFloat = 4

    /// Pure classification of one press-and-release, for quoting.
    nonisolated static func classify(
        down: CGPoint, up: CGPoint, clickCount: Int,
        window: (id: CGWindowID, owner: pid_t)?, ownPID: pid_t
    ) -> Gesture {
        guard let window, window.owner != ownPID else { return .none }
        if hypot(up.x - down.x, up.y - down.y) > dragDistance || clickCount >= 2 {
            return .selection
        }
        return .none
    }

    /// Pure: what ⌥S may shoot — the front app's front window, unless that is
    /// Type4Me or the window being dictated into.
    nonisolated static func shootable(
        front: (pid: pid_t, window: CGWindowID)?, ownPID: pid_t, targetPID: pid_t?, targetWindowID: CGWindowID?
    ) -> Bool {
        guard let front, front.pid != ownPID else { return false }
        return !(front.pid == targetPID && front.window == targetWindowID)
    }

    private let ownPID: pid_t
    private let targetPID: pid_t?
    private let targetWindowID: CGWindowID?
    private let deliver: (Capture) -> Void
    private let awayChanged: (Bool) -> Void
    private var monitors: [Any] = []
    private var downPoint: CGPoint?
    private var downWindow: WindowHit?
    private var gestureStartedAt: TimeInterval = 0

    private var tap: DictationShortcutTap?
    private var timer: Timer?
    private var isAway = false
    private var region: RegionCaptureOverlay?

    struct WindowHit: Equatable {
        let id: CGWindowID
        let owner: pid_t
        let frame: CGRect
    }

    init(
        ownPID: pid_t, targetPID: pid_t?, targetWindowID: CGWindowID?,
        deliver: @escaping (Capture) -> Void, awayChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.ownPID = ownPID
        self.targetPID = targetPID
        self.targetWindowID = targetWindowID
        self.deliver = deliver
        self.awayChanged = awayChanged
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            let point = event.locationInWindow
            let clicks = event.clickCount
            MainActor.assumeIsolated { self?.mouseDown(at: point, clickCount: clicks) }
        }) { monitors.append(down) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            let clicks = event.clickCount
            let point = event.locationInWindow
            MainActor.assumeIsolated { self?.mouseUp(at: point, clickCount: clicks) }
        }) { monitors.append(up) }

        let tap = DictationShortcutTap { [weak self] shortcut in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch shortcut {
                    case .window: self?.shootFrontWindow()
                    case .region: self?.captureRegion()
                    case .cancelRegion: self?.region?.cancel()
                    }
                }
            }
        }
        if tap.start() { self.tap = tap }

        // Whether the user is in another window, for the tray's shortcut hint.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAway() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkAway()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        tap?.stop()
        tap = nil
        region?.cancel()
        region = nil
        DictationRegionCaptureState.isActive = false
        setAway(false)
    }

    // MARK: - Window shots

    private func frontWindow() -> WindowHit? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.frontWindow(of: app.processIdentifier)
    }

    private func checkAway() {
        let front = frontWindow()
        setAway(Self.shootable(
            front: front.map { ($0.owner, $0.id) }, ownPID: ownPID, targetPID: targetPID, targetWindowID: targetWindowID
        ))
    }

    private func setAway(_ away: Bool) {
        guard away != isAway else { return }
        isAway = away
        awayChanged(away)
    }

    /// ⌥S: the window in front, now.
    func shootFrontWindow() {
        guard region == nil else { return }
        let front = frontWindow()
        guard let front, Self.shootable(
            front: (front.owner, front.id), ownPID: ownPID, targetPID: targetPID, targetWindowID: targetWindowID
        ) else {
            DebugFileLogger.log("attachments: ⌥S on the dictation window, nothing shot")
            DictationAttachments.shared.showNotice(.switchWindowFirst)
            return
        }
        AttachmentEffects.flash(front.frame)
        DebugFileLogger.log("attachments: shortcut window=\(front.id)")
        deliver(.window(front.id, front.frame))
    }

    // MARK: - Box capture

    func captureRegion() {
        guard region == nil else { return }
        let overlay = RegionCaptureOverlay { [weak self] rect in
            guard let self else { return }
            self.region = nil
            DictationRegionCaptureState.isActive = false
            self.tap?.setRegionActive(false)
            if let rect {
                AttachmentEffects.flash(rect)
                DebugFileLogger.log("attachments: region \(Int(rect.width))x\(Int(rect.height))")
                self.deliver(.region(rect))
            }
        }
        region = overlay
        DictationRegionCaptureState.isActive = true
        tap?.setRegionActive(true)
        overlay.show()
    }

    // MARK: - Quotes

    private func mouseDown(at point: CGPoint, clickCount: Int) {
        // A double or triple click began with its first press.
        if clickCount <= 1 { gestureStartedAt = CACurrentMediaTime() }
        downPoint = point
        downWindow = Self.window(at: point, excluding: ownPID)
    }

    private func mouseUp(at up: CGPoint, clickCount: Int) {
        guard let down = downPoint else { return }
        let hit = downWindow
        downPoint = nil
        guard Self.classify(
            down: down, up: up, clickCount: clickCount,
            window: hit.map { ($0.id, $0.owner) }, ownPID: ownPID
        ) == .selection, let owner = hit?.owner else { return }
        let dragBox = CGRect(
            x: min(down.x, up.x), y: min(down.y, up.y) - 8,
            width: max(abs(up.x - down.x), 16), height: abs(up.y - down.y) + 20
        )
        let startedAt = gestureStartedAt
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
            self.deliver(.quote(text, read?.bounds ?? dragBox, startedAt: startedAt))
        }
    }

    // MARK: - Coordinates

    private static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func windowServerPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryMaxY - p.y) }

    static func windowServerRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(_ r: CGRect) -> CGRect { windowServerRect(r) }

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

    /// An app's front-most ordinary window, in AppKit coordinates.
    static func frontWindow(of pid: pid_t) -> WindowHit? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40
            else { continue }
            return WindowHit(id: CGWindowID(number), owner: pid, frame: appKitRect(bounds))
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
